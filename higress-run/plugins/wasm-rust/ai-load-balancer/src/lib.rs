use proxy_wasm::traits::*;
use proxy_wasm::types::*;
use std::time::Duration;

#[no_mangle]
pub fn _start() {
    proxy_wasm::set_log_level(LogLevel::Trace);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> { Box::new(AiLoadBalancerRoot) });
}

struct AiLoadBalancerRoot;

impl Context for AiLoadBalancerRoot {}

impl RootContext for AiLoadBalancerRoot {
    fn on_vm_start(&mut self, _vm_configuration_size: usize) -> bool {
        log::info!("AI Load Balancer (Rust) VM started");
        true
    }

    fn create_http_context(&self, _context_id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(AiLoadBalancerHttp))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

struct AiLoadBalancerHttp;

impl Context for AiLoadBalancerHttp {}

impl HttpContext for AiLoadBalancerHttp {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        Action::Continue
    }
}
