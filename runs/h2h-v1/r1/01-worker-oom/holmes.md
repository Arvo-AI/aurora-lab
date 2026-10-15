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
Lazily initializing toolset kubernetes/core...                                  
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_tabular_query: filter: kubectl get pods              
columns=''NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerSta
tuses[0].restartCount,NODE:.spec.nodeName'' filter=worker                       
  Finished #1 in 0.40s, output length: 1,314 characters (19 lines) - /show 1 to 
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
Lazily initializing toolset bash...                                             
Running tool #3 fetch_pod_logs: Fetch Logs (pod=worker-86f68b9bf6-2vsst,        
namespace=shop)                                                                 
✅ Toolset bash                                                                 
Running tool #2 bash: kubectl describe pod worker-86f68b9bf6-2vsst -n shop      
Executing bash command: kubectl describe pod worker-86f68b9bf6-2vsst -n shop    
  Finished #2 in 0.08s, output length: 3,302 characters (78 lines) - /show 2 to 
view contents                                                                   
  Finished #3 in 0.10s, output length: 771 characters (20 lines) - /show 3 to   
view contents                                                                   
The AI requested 2 tool call(s).                                                
                                                                                
Running tool #4 bash: kubectl get deployment worker -n shop -o yaml | grep -A5  
'env:\|resources:\|image:'                                                      
Executing bash command: kubectl get deployment worker -n shop -o yaml | grep -A5
'env:\|resources:\|image:'                                                      
Running tool #5 bash: kubectl get rs -n shop -l app=worker -o wide; echo '---'; 
kubectl rollout history deployment worker -n shop                               
  Tool 'bash' requires approval: Command requires approval. Segment(s) not in   
allow list: 'kubectl rollout history deployment worker -n shop'                 
The AI requested 2 tool call(s).                                                
  Finished #4 in 0.03s, output length: 361 characters (13 lines) - /show 4 to   
view contents                                                                   
                                                                                
Running tool #6 bash: kubectl get rs -n shop -l app=worker -o wide              
Executing bash command: kubectl get rs -n shop -l app=worker -o wide            
Running tool #7 kubernetes_jq_query: jq query: kubectl get deployments | jq     
''.items[] | select(.metadata.name=="worker" and .metadata.namespace=="shop") | 
{annotations: .metadata.annotations, creationTimestamp:                         
.metadata.creationTimestamp, generation: .metadata.generation}''                
  Finished #6 in 0.07s, output length: 397 characters (4 lines) - /show 6 to    
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #7 in 0.26s, output length: 1,018 characters (15 lines) - /show 7 to 
view contents                                                                   
                                                                                
Running tool #8 bash: kubectl get configmap api-code -n shop -o                 
jsonpath='{.data.worker\.py}' 2>/dev/null | head -100                           
Executing bash command: kubectl get configmap api-code -n shop -o               
jsonpath='{.data.worker\.py}' 2>/dev/null | head -100                           
  Finished #8 in 0.06s, output length: 450 characters (10 lines) - /show 8 to   
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
AI: Root cause confirmed.                                                           

Pod: worker-86f68b9bf6-2vsst (namespace shop) is CrashLooping with OOMKilled    
(exit code 137), restart count 3, Back-off restarting failed container events   
from kubelet.                                                                   

What changed: BATCH_SIZE env var on the worker Deployment was raised from 500 → 
2500.                                                                           

 • The deployment's last-applied-configuration annotation (revision 2) still    
   shows BATCH_SIZE=500, but the live pod spec has BATCH_SIZE=2500 — meaning the
   change was applied via a direct edit/patch (not kubectl apply), bypassing the
   usual applied-config tracking.                                               
 • worker.py (from ConfigMap api-code) allocates batch buffers of 100 KiB each: 
   buf = [bytearray(100*1024) for _ in range(batch)]. At batch=500 that's ~50   
   MiB; at batch=2500 it's ~250 MiB, which blows past the container's memory    
   limit of 192Mi (request is only 64Mi). The container is killed by the OOM    
   killer almost immediately after start (~20-40s).                             

Fix: either revert BATCH_SIZE back to 500 (or a value whose 100KiB * BATCH_SIZE 
comfortably fits under the limit), or raise the memory limit to cover 2500 *    
100KiB (~250Mi+ plus headroom, e.g. 320–384Mi). Also re-apply via kubectl       
apply/your usual GitOps/Helm path so the live config and tracked config stay in 
sync and this kind of drift is caught in review.                                
