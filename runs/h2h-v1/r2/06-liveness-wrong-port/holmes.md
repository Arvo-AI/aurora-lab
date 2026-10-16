Interactive mode disabled when reading piped input
Model 'bedrock/us.anthropic.claude-sonnet-5' has no entry in litellm's cost map 
and no input/output_cost_per_token configured. Usage event costs for this model 
will be 0. Add input_cost_per_token and output_cost_per_token to its            
model_list.yaml entry to enable cost tracking.                                  
Loaded models: ['bedrock/us.anthropic.claude-sonnet-5']                         
User: KubePodCrashLooping: api pods in namespace shop restart every minute or 
so. Namespace shop, cluster kind-aurora-lab. Find the root cause and say what 
changed.
Using selected model: bedrock/us.anthropic.claude-sonnet-5                      
Model: bedrock/us.anthropic.claude-sonnet-5, 1M context, 120K max response      
(default, change with --model, for all options see                              
https://holmesgpt.dev/ai-providers)                                             
Using 28 datasources (toolsets). To refresh: use flag `--refresh-toolsets`      
Lazily initializing toolset kubernetes/core...                                  
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_tabular_query: filter: kubectl get pods              
columns=''NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerSta
tuses[0].restartCount,REASON:.status.containerStatuses[0].lastState.terminated.r
eason,EXIT:.status.containerStatuses[0].lastState.terminated.exitCode''         
filter=api                                                                      
  Finished #1 in 0.43s, output length: 434 characters (10 lines) - /show 1 to   
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
Running tool #2 kubernetes_jq_query: jq query: kubectl get pods | jq ''.items[] 
| select(.metadata.namespace=="shop" and (.metadata.name|test("^api-"))) |      
{name:.metadata.name, restarts:.status.containerStatuses[0].restartCount,       
lastState:.status.containerStatuses[0].lastState,                               
resources:.spec.containers[0].resources}''                                      
Running tool #3 kubernetes_jq_query: jq query: kubectl get deployments | jq     
''.items[] | select(.metadata.namespace=="shop" and .metadata.name=="api") |    
{name:.metadata.name, replicas:.spec.replicas,                                  
containers:.spec.template.spec.containers}''                                    
  Finished #3 in 0.42s, output length: 1,774 characters (75 lines) - /show 3 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #2 in 0.44s, output length: 1,216 characters (51 lines) - /show 2 to 
view contents                                                                   
                                                                                
Lazily initializing toolset bash...                                             
Running tool #5 fetch_pod_logs: Fetch Logs (pod=api-c7b987b4d-cpcdj,            
namespace=shop)                                                                 
✅ Toolset bash                                                                 
Running tool #4 bash: kubectl describe pod api-c7b987b4d-cpcdj -n shop          
Executing bash command: kubectl describe pod api-c7b987b4d-cpcdj -n shop        
  Finished #4 in 0.12s, output length: 3,704 characters (79 lines) - /show 4 to 
view contents                                                                   
  Finished #5 in 0.15s, output length: 1,631 characters (43 lines) - /show 5 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
                                                                                
Running tool #6 bash: kubectl get configmap api-code -n shop -o yaml | head -100
Running tool #7 bash: kubectl get deployment api -n shop -o yaml | grep -A5     
"livenessProbe\|readinessProbe"; echo "---rollout history---"; kubectl describe 
deployment api -n shop | tail -30; echo "---rs---"; kubectl get rs...           
Executing bash command: kubectl get deployment api -n shop -o yaml | grep -A5   
"livenessProbe\|readinessProbe"; echo "---rollout history---"; kubectl describe 
deployment api -n shop | tail -30; echo "---rs---"; kubectl get rs -n shop -l   
app=api                                                                         
Executing bash command: kubectl get configmap api-code -n shop -o yaml | head   
-100                                                                            
  Finished #6 in 0.10s, output length: 4,736 characters (71 lines) - /show 6 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #7 in 0.23s, output length: 3,076 characters (56 lines) - /show 7 to 
view contents                                                                   
                                                                                
AI: Found it.                                                                       

Root cause: The api Deployment's livenessProbe targets port 8081, but the       
application only listens on port 8080 (confirmed in pod logs: api listening on  
:8080, and in the configmap-mounted api.py which binds only PORT=8080). Every   
~60s (15s initial delay + 3×10s period) the liveness probe fails with connection
refused, kubelet kills the container, and it restarts — matching the "restarts  
every minute" symptom exactly. Exit code 137 is SIGKILL from the kubelet, not an
OOM kill (the container never actually ran out of memory).                      

What changed: This is a very recent change — the api deployment's NewReplicaSet 
api-c7b987b4d was created only ~2.5 minutes ago (rollout events:                
ScalingReplicaSet at 08:09:47–08:09:56 UTC), replacing api-f64486c4c. The drift 
is visible in the live object vs. its                                           
kubectl.kubernetes.io/last-applied-configuration annotation:                    

 • Last-applied (intended) config: livenessProbe.httpGet.port: 8080 — same as   
   readiness probe.                                                             
 • Live spec actually running: livenessProbe.httpGet.port: 8081.                

This mismatch indicates someone ran a direct edit/patch against the Deployment  
(e.g. kubectl edit/kubectl patch) that bumped the liveness probe port to 8081   
without going through the applied manifest, triggering the rollout to the       
crash-looping ReplicaSet api-c7b987b4d.                                         

Evidence:                                                                       

                                                                                
 Warning  Unhealthy  kubelet  Liveness probe failed: Get                        
 "http://10.244.2.115:8081/healthz": dial tcp 10.244.2.115:8081: connect:       
 connection refused                                                             
 Normal   Killing    kubelet  Container api failed liveness probe, will be      
 restarted                                                                      
                                                                                

Pod logs confirm app health works fine on 8080 (GET /healthz HTTP/1.1" 200)     
right up until the kill.                                                        

Fix: Set livenessProbe.httpGet.port back to 8080 on the api Deployment in       
namespace shop (matching the readiness probe and the container's actual         
listening port):                                                                

                                                                                
 kubectl patch deployment api -n shop --type=json \                             
   -p='[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/ 
 tpGet/port","value":8080}]'                                                    
                                                                                

Other pods checked: readiness probe on port 8080 succeeds initially (200 OK)    
before each kill, confirming the app itself is healthy — this is purely a probe 
misconfiguration, not an application bug.                                       
