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
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_tabular_query: filter: kubectl get pods              
columns=''NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerSta
tuses[0].restartCount,NODE:.spec.nodeName'' filter=worker                       
Running tool #2 kubernetes_jq_query: jq query: kubectl get deployments | jq     
''.items[] | select(.metadata.namespace=="shop" and .metadata.name=="worker")'' 
  Finished #1 in 0.39s, output length: 1,314 characters (19 lines) - /show 1 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #2 in 0.42s, output length: 9,700 characters (284 lines) - /show 2 to
view contents                                                                   
                                                                                
Running tool #3 kubernetes_jq_query: jq query: kubectl get pods | jq ''.items[] 
| select(.metadata.namespace=="shop" and                                        
.metadata.name=="worker-86f68b9bf6-qrgkr") | {name:.metadata.name,              
status:.status.containerStatuses}''                                             
Running tool #4 fetch_pod_logs: Fetch Logs (pod=worker-86f68b9bf6-qrgkr,        
namespace=shop)                                                                 
  Finished #4 in 0.08s, output length: 772 characters (20 lines) - /show 4 to   
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #3 in 0.27s, output length: 2,363 characters (83 lines) - /show 3 to 
view contents                                                                   
                                                                                
AI: Root cause confirmed: shop/worker is being OOMKilled.                           

What changed: The deployment worker was edited moments ago (kubectl-set field   
manager, timestamp 2026-10-15T09:03:50Z) — env var BATCH_SIZE was bumped from   
500 → 2500. The new ReplicaSet worker-86f68b9bf6 rolled out right after.        

Evidence:                                                                       

 • Pod worker-86f68b9bf6-qrgkr container worker: current state terminated,      
   reason: OOMKilled, exitCode 137; previous state also OOMKilled, exitCode 137.
   Restart count 4 and climbing → CrashLoopBackOff.                             
 • Logs show only worker started, batch size 2500 before each kill — container  
   dies almost immediately after loading the batch.                             
 • Container memory limit is only 192Mi (request 64Mi), set in the deployment   
   spec. Processing a batch of 2500 items (5x the original 500) exceeds this    
   limit, triggering the kernel OOM killer.                                     

Conclusion: Someone increased BATCH_SIZE from 500 to 2500 on the worker         
deployment without raising the memory limit (still 192Mi), causing the worker to
exceed its memory limit and get OOMKilled on every start, hence                 
CrashLoopBackOff.                                                               

Fix options:                                                                    

 1 Revert BATCH_SIZE back to 500 (or a value that fits in 192Mi), e.g.: kubectl 
   set env deployment/worker -n shop BATCH_SIZE=500                             
 2 If 2500 is required, raise the memory limit/request accordingly (test to find
   real usage, then set e.g. limits.memory: 512Mi or higher) via kubectl edit   
   deployment worker -n shop.                                                   
