Interactive mode disabled when reading piped input
Model 'bedrock/us.anthropic.claude-sonnet-5' has no entry in litellm's cost map 
and no input/output_cost_per_token configured. Usage event costs for this model 
will be 0. Add input_cost_per_token and output_cost_per_token to its            
model_list.yaml entry to enable cost tracking.                                  
Loaded models: ['bedrock/us.anthropic.claude-sonnet-5']                         
User: KubePodCrashLooping: pod worker in namespace shop is restarting 
repeatedly. Namespace shop, cluster kind-aurora-lab. Find the root cause and say
what changed.
Using selected model: bedrock/us.anthropic.claude-sonnet-5                      
Model: bedrock/us.anthropic.claude-sonnet-5, 1M context, 120K max response      
(default, change with --model, for all options see                              
https://holmesgpt.dev/ai-providers)                                             
Using 28 datasources (toolsets). To refresh: use flag `--refresh-toolsets`      
Lazily initializing toolset bash...                                             
✅ Toolset bash                                                                 
Running tool #1 bash: kubectl get pods -n shop -o wide | grep worker            
Executing bash command: kubectl get pods -n shop -o wide | grep worker          
Running tool #2 bash: kubectl describe pod -n shop -l app=worker 2>/dev/null || 
kubectl get pods -n shop -o name | grep worker                                  
Executing bash command: kubectl describe pod -n shop -l app=worker 2>/dev/null  
|| kubectl get pods -n shop -o name | grep worker                               
  Finished #1 in 0.09s, output length: 942 characters (8 lines) - /show 1 to    
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #2 in 0.09s, output length: 3,354 characters (78 lines) - /show 2 to 
view contents                                                                   
                                                                                
Running tool #3 bash: kubectl get deployment worker -n shop -o yaml | head -80  
Executing bash command: kubectl get deployment worker -n shop -o yaml | head -80
Running tool #5 fetch_pod_logs: Fetch Logs (pod=worker-86f68b9bf6-dvxbd,        
namespace=shop)                                                                 
Running tool #4 bash: kubectl get configmap api-code -n shop -o yaml | head -200
Executing bash command: kubectl get configmap api-code -n shop -o yaml | head   
-200                                                                            
  Finished #3 in 0.07s, output length: 2,652 characters (81 lines) - /show 3 to 
view contents                                                                   
The AI requested 3 tool call(s).                                                
  Finished #4 in 0.10s, output length: 4,736 characters (71 lines) - /show 4 to 
view contents                                                                   
  Finished #5 in 0.11s, output length: 772 characters (20 lines) - /show 5 to   
view contents                                                                   
                                                                                
AI: Root cause confirmed: worker pod OOMKilled repeatedly.                          

What happened:                                                                  

 • Pod worker-86f68b9bf6-dvxbd in namespace shop is in CrashLoopBackOff, restart
   count 3, last 2 terminations: OOMKilled / exit code 137.                     
 • Container memory limit: 192Mi, request 64Mi.                                 
 • worker.py (from ConfigMap api-code) allocates BATCH_SIZE buffers of 100 KiB  
   each on every loop iteration: buf = [bytearray(100*1024) for _ in            
   range(batch)].                                                               
 • Log confirms: worker started, batch size 2500 → 2500 × 100 KiB ≈ 244 MiB,    
   which exceeds the 192Mi limit → kernel OOM-kills the container immediately on
   the first batch allocation.                                                  

What changed:                                                                   

 • Deployment worker is at revision 2 (deployment.kubernetes.io/revision: "2"), 
   created 2026-10-16T07:57:54Z.                                                
 • The kubectl.kubernetes.io/last-applied-configuration annotation (the         
   previous/intended spec) shows BATCH_SIZE=500 (500 × 100 KiB ≈ 49 MiB — safely
   under the 192Mi limit).                                                      
 • The live pod spec has BATCH_SIZE=2500, 5x higher than the last-applied config
   — this value was changed (e.g. via kubectl edit/kubectl set env or a direct  
   patch) without updating memory limits accordingly.                           

Fix: either lower BATCH_SIZE back to a safe value (e.g. 500, well under limit), 
or raise the worker container's memory limit to comfortably exceed BATCH_SIZE × 
100KiB (e.g. ≥512Mi for BATCH_SIZE=2500) plus Python/runtime overhead. Recommend
reverting BATCH_SIZE to 500 to match the deployment's own                       
last-applied-configuration, since that's the known-good value, and keeping      
limits aligned with whatever BATCH_SIZE is chosen going forward.                
