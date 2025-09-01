use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use signal_hook::{consts::SIGTERM, consts::SIGINT, iterator::Signals};

struct DummyResourceConsumer {
    running: Arc<AtomicBool>,
    memory_holder: Vec<Vec<u8>>,
}

impl DummyResourceConsumer {
    fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(true)),
            memory_holder: Vec::new(),
        }
    }
    
    fn consume_memory(&mut self) {
        // Allocate 10 MB of memory
        let memory_mb = 10;
        println!("Allocating {} MB of memory...", memory_mb);
        
        let mb_size = 1024 * 1024;
        for _ in 0..memory_mb {
            let mut chunk = vec![0u8; mb_size];
            // Touch the memory to ensure it's actually allocated
            chunk[0] = 0xFF;
            chunk[mb_size - 1] = 0xFF;
            self.memory_holder.push(chunk);
        }
        
        println!("Memory allocation complete: {} MB", memory_mb);
    }
    
    fn consume_cpu(&self) {
        // Use 5% CPU
        let running = self.running.clone();
        
        thread::spawn(move || {
            while running.load(Ordering::Relaxed) {
                // Small CPU burn
                let mut counter: u64 = 0;
                for i in 0..100000 {
                    counter = counter.wrapping_add(i);
                }
                std::hint::black_box(counter);
                
                // Sleep most of the time (95%)
                thread::sleep(Duration::from_millis(95));
            }
        });
    }
    
    fn setup_signal_handler(&self) -> thread::JoinHandle<()> {
        let running = self.running.clone();
        
        thread::spawn(move || {
            let mut signals = Signals::new(&[SIGTERM, SIGINT]).unwrap();
            
            for sig in signals.forever() {
                println!("Received signal {}, shutting down...", sig);
                running.store(false, Ordering::Relaxed);
                break;
            }
        })
    }
    
    fn run(&mut self) {
        println!("Starting Dummy Service - PID: {}", std::process::id());
        println!("Using 5% CPU and 10 MB RAM");
        
        let signal_thread = self.setup_signal_handler();
        
        self.consume_memory();
        self.consume_cpu();
        
        let mut cycle = 0u64;
        let start_time = Instant::now();
        
        while self.running.load(Ordering::Relaxed) {
            cycle += 1;
            
            // Log every 10 seconds
            if cycle % 10 == 0 {
                let uptime = start_time.elapsed().as_secs();
                println!("[Cycle: {}] Uptime: {}s", cycle, uptime);
            }
            
            thread::sleep(Duration::from_secs(1));
        }
        
        println!("Service stopped");
        let _ = signal_thread.join();
    }
}

fn main() {
    let mut service = DummyResourceConsumer::new();
    service.run();
}