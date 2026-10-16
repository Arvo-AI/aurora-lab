Interactive mode disabled when reading piped input
Model 'bedrock/us.anthropic.claude-sonnet-5' has no entry in litellm's cost map 
and no input/output_cost_per_token configured. Usage event costs for this model 
will be 0. Add input_cost_per_token and output_cost_per_token to its            
model_list.yaml entry to enable cost tracking.                                  
Loaded models: ['bedrock/us.anthropic.claude-sonnet-5']                         
User: KubePodCrashLooping  namespace=shop deployment=worker: Pod shop/worker 
(container worker) is in waiting state (reason: CrashLoopBackOff). Namespace 
shop, cluster kind-aurora-lab. Find the root cause and say what changed.
Using selected model: bedrock/us.anthropic.claude-sonnet-5                      
Model: bedrock/us.anthropic.claude-sonnet-5, 1M context, 120K max response      
(default, change with --model, for all options see                              
https://holmesgpt.dev/ai-providers)                                             
Using 28 datasources (toolsets). To refresh: use flag `--refresh-toolsets`      
Lazily initializing toolset kubernetes/core...                                  
Lazily initializing toolset bash...                                             
✅ Toolset bash                                                                 
Running tool #2 bash: kubectl describe deployment worker -n shop                
Executing bash command: kubectl describe deployment worker -n shop              
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_tabular_query: filter: kubectl get pods              
columns=''NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerSta
tuses[0].restartCount,REASON:.status.containerStatuses[0].state.waiting.reason,L
ASTREASON:.status.containerStatuses[0].lastState.terminated.reason,EXITCODE:.sta
tus.containerStatuses[0].lastState.terminated.exitCode'' filter=worker          
  Finished #2 in 0.09s, output length: 1,813 characters (51 lines) - /show 2 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #1 in 0.32s, output length: 273 characters (8 lines) - /show 1 to    
view contents                                                                   
                                                                                
Running tool #3 bash: kubectl describe pod worker-86f68b9bf6-jrh5f -n shop      
Executing bash command: kubectl describe pod worker-86f68b9bf6-jrh5f -n shop    
Running tool #4 fetch_pod_logs: Fetch Logs (pod=worker-86f68b9bf6-jrh5f,        
namespace=shop)                                                                 
  Finished #3 in 0.10s, output length: 3,304 characters (78 lines) - /show 3 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #4 in 0.11s, output length: 769 characters (20 lines) - /show 4 to   
view contents                                                                   
                                                                                
Running tool #5 bash: kubectl get rs -n shop -l app=worker -o jsonpath='{range  
.items[*]}{.metadata.name}{"\n"}{.spec.template.spec.containers[0].env}{"\n"}{.s
pec.template.spec.containers[0].resources}{"\n\n"}{end}'                        
Executing bash command: kubectl get rs -n shop -l app=worker -o jsonpath='{range
.items[*]}{.metadata.name}{"\n"}{.spec.template.spec.containers[0].env}{"\n"}{.s
pec.template.spec.containers[0].resources}{"\n\n"}{end}'                        
Running tool #6 bash: kubectl get configmap api-code -n shop -o yaml | head -100
Executing bash command: kubectl get configmap api-code -n shop -o yaml | head   
-100                                                                            
  Finished #6 in 0.09s, output length: 4,736 characters (71 lines) - /show 6 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #5 in 0.11s, output length: 449 characters (8 lines) - /show 5 to    
view contents                                                                   
                                                                                
AI: Root cause confirmed: BATCH_SIZE env var change.                                

What changed: Deployment shop/worker revision 2 bumped BATCH_SIZE from 500 →    
2500 (old ReplicaSet worker-6cf88d4b58 had BATCH_SIZE=500, new worker-86f68b9bf6
has BATCH_SIZE=2500). Memory limit stayed at 192Mi (request 64Mi).              

Why it crashes: worker.py (from ConfigMap api-code) allocates batch buffers of  
100 KiB each on every loop iteration: buf = [bytearray(100*1024) for _ in       
range(batch)]. At BATCH_SIZE=500 that's ~50MB — fine. At 2500 that's ~250MB,    
which blows past the 192Mi limit immediately.                                   

Evidence:                                                                       

 • Container worker in pod worker-86f68b9bf6-jrh5f (node aurora-lab-worker2):   
   lastState.terminated.reason=OOMKilled, exitCode 137, restartCount 3,         
   currently in CrashLoopBackOff/BackOff per kubelet event.                     
 • Log line right before each kill: worker started, batch size 2500 — then      
   nothing (OOM kill before it can print "processed batch").                    
 • Deployment worker conditions: Available=False (MinimumReplicasUnavailable).  

Fix: either revert BATCH_SIZE to 500 (or a value that fits in memory), or raise 
the container memory limit to comfortably cover batch * 100KiB plus             
Python/runtime overhead (e.g. ≥320–384Mi for BATCH_SIZE=2500). Also bump the    
memory request accordingly so the scheduler accounts for real usage.            
