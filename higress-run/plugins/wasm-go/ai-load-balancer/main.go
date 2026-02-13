package main

import (
	"math/rand"
	"strconv"

	"github.com/alibaba/higress/plugins/wasm-go/pkg/wrapper"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/tidwall/gjson"
	"github.com/tidwall/resp"
	"github.com/tidwall/sjson"
)

const (
	RewriteModelHeader = "x-rewrite-target-model"
)

func main() {
	wrapper.SetCtx(
		"ai-load-balancer",
		wrapper.ParseConfigBy(parseConfig),
		wrapper.ProcessRequestHeadersBy(onHttpRequestHeaders),
		wrapper.ProcessRequestBodyBy(onHttpRequestBody),
	)
}

type AILoadBalancerConfig struct {
	RedisClient  wrapper.RedisClient
	Providers    []ProviderConfig
	RedisKey     string
	TargetHeader string
}

type ProviderConfig struct {
	Name      string
	MetricKey string
	Model     string
}

func parseConfig(json gjson.Result, config *AILoadBalancerConfig, log wrapper.Log) error {
	serviceName := json.Get("redis.service_name").String()
	if serviceName == "" { serviceName = "redis-svc" }
	config.RedisClient = wrapper.NewRedisClusterClient(wrapper.DnsCluster{
		ServiceName: serviceName,
		Domain:      serviceName,
		Port:        6379,
	})
	_ = config.RedisClient.Init(json.Get("redis.username").String(), json.Get("redis.password").String(), json.Get("redis.timeout").Int())
	
	config.RedisKey = json.Get("redis_key_prefix").String()
	config.TargetHeader = json.Get("target_header").String()
	if config.TargetHeader == "" { config.TargetHeader = "x-selected-provider" }

	providers := json.Get("providers").Array()
	for _, p := range providers {
		config.Providers = append(config.Providers, ProviderConfig{
			Name:      p.Get("name").String(),
			MetricKey: p.Get("key").String(),
			Model:     p.Get("model").String(),
		})
	}
	return nil
}

func onHttpRequestHeaders(ctx wrapper.HttpContext, config AILoadBalancerConfig, log wrapper.Log) types.Action {
	if len(config.Providers) == 0 {
		return types.ActionContinue
	}

	_ = proxywasm.RemoveHttpRequestHeader("content-length")
	_ = proxywasm.SetProperty([]string{"set_decoder_buffer_limit"}, []byte(strconv.Itoa(10*1024*1024)))

	keys := make([]string, len(config.Providers))
	for i, p := range config.Providers {
		keys[i] = config.RedisKey + p.MetricKey
	}

	_ = config.RedisClient.MGet(keys, func(status int, response resp.Value) {
		bestProvider := selectBestProvider(config.Providers, response)
		if bestProvider != nil {
			// 1. 设置 Header 触发 Ingress 路由选择
			proxywasm.ReplaceHttpRequestHeader(config.TargetHeader, bestProvider.Name)
			// 2. 染色用于 Body 改写
			proxywasm.ReplaceHttpRequestHeader(RewriteModelHeader, bestProvider.Model)
		}
		proxywasm.ResumeHttpRequest()
	})

	return types.ActionPause
}

func onHttpRequestBody(ctx wrapper.HttpContext, config AILoadBalancerConfig, body []byte, log wrapper.Log) types.Action {
	model, _ := proxywasm.GetHttpRequestHeader(RewriteModelHeader)
	if model == "" {
		return types.ActionContinue
	}

	newBody, err := sjson.SetBytes(body, "model", model)
	if err == nil {
		_ = proxywasm.ReplaceHttpRequestBody(newBody)
	}
	
	_ = proxywasm.RemoveHttpRequestHeader(RewriteModelHeader)
	return types.ActionContinue
}

func selectBestProvider(providers []ProviderConfig, response resp.Value) *ProviderConfig {
	if response.Error() != nil || response.Type() != resp.Array {
		return &providers[rand.Intn(len(providers))]
	}
	values := response.Array()
	bestIdx, minUtil := -1, 101
	for i, val := range values {
		if i < len(providers) && !val.IsNull() {
			util, _ := strconv.Atoi(val.String())
			if util < minUtil {
				minUtil, bestIdx = util, i
			}
		}
	}
	if bestIdx != -1 { return &providers[bestIdx] }
	return &providers[rand.Intn(len(providers))]
}
