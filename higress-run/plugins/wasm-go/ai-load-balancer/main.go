package main

import (
	"math/rand"
	"strconv"

	"github.com/alibaba/higress/plugins/wasm-go/pkg/wrapper"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/tidwall/gjson"
	"github.com/tidwall/resp"
)

func main() {
	wrapper.SetCtx(
		"ai-load-balancer",
		wrapper.ParseConfigBy(parseConfig),
		wrapper.ProcessRequestHeadersBy(onHttpRequestHeaders),
	)
}

type AILoadBalancerConfig struct {
	RedisClient wrapper.RedisClient
	Providers   []ProviderConfig
	RedisKey    string
	HeaderKey   string
}

type ProviderConfig struct {
	Name      string
	MetricKey string
}

func parseConfig(json gjson.Result, config *AILoadBalancerConfig, log wrapper.Log) error {
	serviceName := json.Get("redis.service_name").String()
	servicePort := json.Get("redis.service_port").Int()
	username := json.Get("redis.username").String()
	password := json.Get("redis.password").String()
	timeout := json.Get("redis.timeout").Int()

	if serviceName == "" {
		log.Errorf("ai-load-balancer: redis.service_name is required")
		return nil
	}
	if servicePort == 0 {
		servicePort = 6379
	}
	if timeout == 0 {
		timeout = 1000
	}

	// DnsCluster: ClusterName() => outbound|<Port>||<ServiceName>.dns
	// McpBridge 中 Redis 注册为 name=higress-redis, type=dns
	// 所以这里 ServiceName 传 "higress-redis", 生成集群名: outbound|6379||higress-redis.dns
	config.RedisClient = wrapper.NewRedisClusterClient(wrapper.DnsCluster{
		ServiceName: serviceName,
		Domain:      serviceName, // HostName() 返回 Domain
		Port:        servicePort,
	})
	err := config.RedisClient.Init(username, password, timeout)
	if err != nil {
		log.Errorf("ai-load-balancer: redis init failed: %v", err)
	}

	config.RedisKey = json.Get("redis_key_prefix").String()
	if config.RedisKey == "" {
		config.RedisKey = "ai_metric:"
	}

	config.HeaderKey = json.Get("target_header").String()
	if config.HeaderKey == "" {
		config.HeaderKey = "x-selected-provider"
	}

	providers := json.Get("providers").Array()
	for _, p := range providers {
		config.Providers = append(config.Providers, ProviderConfig{
			Name:      p.Get("name").String(),
			MetricKey: p.Get("key").String(),
		})
	}

	log.Infof("ai-load-balancer: config parsed, %d providers, redis=%s:%d, prefix=%s, header=%s",
		len(config.Providers), serviceName, servicePort, config.RedisKey, config.HeaderKey)
	return nil
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, config AILoadBalancerConfig, log wrapper.Log) types.Action {
	log.Infof("ai-load-balancer: onHttpRequestHeaders called")

	if len(config.Providers) == 0 {
		log.Warnf("ai-load-balancer: no providers configured, passing through")
		return types.ActionContinue
	}

	keys := make([]string, len(config.Providers))
	for i, p := range config.Providers {
		keys[i] = config.RedisKey + p.MetricKey
	}
	log.Infof("ai-load-balancer: querying Redis for keys: %v", keys)

	// SDK v1.3.5 的 RedisResponseCallback 签名: func(status int, response resp.Value)
	err := config.RedisClient.MGet(keys, func(status int, response resp.Value) {
		if response.Error() != nil {
			log.Errorf("ai-load-balancer: Redis MGET error (status=%d): %v", status, response.Error())
			proxywasm.ResumeHttpRequest()
			return
		}

		if response.Type() != resp.Array {
			log.Errorf("ai-load-balancer: Redis MGET returned non-array type: %d", response.Type())
			proxywasm.ResumeHttpRequest()
			return
		}

		bestProvider := selectBestProvider(config.Providers, response.Array(), log)

		if bestProvider != "" {
			log.Infof("ai-load-balancer: Selected: %s", bestProvider)
			proxywasm.ReplaceHttpRequestHeader(config.HeaderKey, bestProvider)
		} else {
			log.Warnf("ai-load-balancer: no provider selected")
		}

		proxywasm.ResumeHttpRequest()
	})

	if err != nil {
		log.Errorf("ai-load-balancer: Redis call initiation failed: %v", err)
		return types.ActionContinue
	}

	return types.ActionPause
}

func selectBestProvider(providers []ProviderConfig, values []resp.Value, log wrapper.Log) string {
	bestIdx := -1
	minUtil := 101

	for i, val := range values {
		if i >= len(providers) {
			break
		}

		if val.IsNull() {
			log.Warnf("ai-load-balancer: metric missing for %s, skipping", providers[i].Name)
			continue
		}

		s := val.String()
		util, err := strconv.Atoi(s)
		if err != nil {
			log.Warnf("ai-load-balancer: invalid metric for %s: '%s'", providers[i].Name, s)
			continue
		}

		log.Infof("ai-load-balancer: provider=%s metric=%d", providers[i].Name, util)

		if util < minUtil {
			minUtil = util
			bestIdx = i
		}
	}

	if bestIdx != -1 {
		return providers[bestIdx].Name
	}

	if len(providers) > 0 {
		log.Warnf("ai-load-balancer: no valid metrics, falling back to random selection")
		return providers[rand.Intn(len(providers))].Name
	}

	return ""
}
