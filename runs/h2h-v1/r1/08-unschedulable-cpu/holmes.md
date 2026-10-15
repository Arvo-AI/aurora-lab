Interactive mode disabled when reading piped input
Model 'bedrock/us.anthropic.claude-sonnet-5' has no entry in litellm's cost map 
and no input/output_cost_per_token configured. Usage event costs for this model 
will be 0. Add input_cost_per_token and output_cost_per_token to its            
model_list.yaml entry to enable cost tracking.                                  
Loaded models: ['bedrock/us.anthropic.claude-sonnet-5']                         
User: KubePodNotReady: worker pod in namespace shop has been Pending for over 5 
minutes. Namespace shop, cluster kind-aurora-lab. Find the root cause and say 
what changed.
Using selected model: bedrock/us.anthropic.claude-sonnet-5                      
Model: bedrock/us.anthropic.claude-sonnet-5, 1M context, 120K max response      
(default, change with --model, for all options see                              
https://holmesgpt.dev/ai-providers)                                             
Using 28 datasources (toolsets). To refresh: use flag `--refresh-toolsets`      
Lazily initializing toolset kubernetes/core...                                  
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_tabular_query: filter: kubectl get pods              
columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,CREATED:.m
etadata.creationTimestamp' filter=worker                                        
Running tool #2 kubernetes_jq_query: jq query: kubectl get events | jq          
''.items[] | select(.metadata.namespace=="shop") | {name:.involvedObject.name,  
reason:.reason, message:.message, time:.lastTimestamp}''                        
  Finished #1 in 0.61s, output length: 1,670 characters (20 lines) - /show 1 to 
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #2 in 0.64s, output length: 9,212 characters (289 lines) - /show 2 to
view contents                                                                   
                                                                                
Running tool #3 kubernetes_jq_query: jq query: kubectl get deployments | jq     
''.items[] | select(.metadata.namespace=="shop" and .metadata.name=="worker") | 
{name:.metadata.name, replicas:.spec.replicas, strategy:.spec.strategy,         
resources:.spec.template.spec.containers[0].resources,                          
image:.spec.template.spec.containers[0].image, revision:.metadata.annotations}''
Running tool #4 kubernetes_jq_query: jq query: kubectl get nodes | jq ''.items[]
| {name:.metadata.name, taints:.spec.taints, allocatable:.status.allocatable,   
capacity:.status.capacity}''                                                    
Lazily initializing toolset kubernetes/live-metrics...                          
✅ Toolset kubernetes/live-metrics                                              
Running tool #5 kubectl_top_pods: kubectl top pods -A                           
  Finished #5 in 0.03s, output length: 2,230 characters (22 lines) - /show 5 to 
view contents                                                                   
The AI requested 3 tool call(s).                                                
  Finished #4 in 0.32s, output length: 1,319 characters (60 lines) - /show 4 to 
view contents                                                                   
  Finished #3 in 0.33s, output length: 1,356 characters (32 lines) - /show 3 to 
view contents                                                                   
                                                                                
Running tool #6 kubernetes_jq_query: jq query: kubectl get replicasets | jq     
''.items[] | select(.metadata.namespace=="shop" and                             
(.metadata.name|test("^worker-"))) | {name:.metadata.name,                      
revision:.metadata.annotations["deployment.kubernetes.io/revision"],            
resources:.spec.template.spec.containers[0].resources}''                        
  Finished #6 in 0.60s, output length: 574 characters (33 lines) - /show 6 to   
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
AI: 
                                   Root Cause                                   

Pod worker-7fdf4ffb67-p9pwt (namespace shop) is stuck Pending due to            
unschedulable CPU request, not a node capacity/outage issue.                    

What changed: The worker Deployment was updated (revision 1 → 2 at              
2026-10-15T08:51:14Z), rolling out a new ReplicaSet worker-7fdf4ffb67. The new  
pod template's CPU request was changed from 50m (0.05 cores, revision 1 /       
worker-6cf88d4b58) to 64 (64 whole cores) — almost certainly a typo missing the 
m suffix (intended 64m, got 64).                                                

Evidence:                                                                       

 • FailedScheduling event for worker-7fdf4ffb67-p9pwt: "0/3 nodes are available:
   1 node(s) had untolerated taint(s), 2 Insufficient cpu. preemption: not      
   helpful."                                                                    
 • Both worker nodes (aurora-lab-worker, aurora-lab-worker2) have only 10       
   allocatable CPUs each (confirmed via node status) — nowhere near the         
   requested 64 cores.                                                          
 • The 3rd node, aurora-lab-control-plane, is excluded by its standard          
   node-role.kubernetes.io/control-plane:NoSchedule taint (expected, unrelated).
 • The old ReplicaSet worker-6cf88d4b58 (revision 1, request cpu: 50m) still has
   its pod worker-6cf88d4b58-q9gtk Running fine on aurora-lab-worker —          
   confirming the rollout, not node health, is the issue.                       

So this is a self-inflicted scheduling failure from the deployment edit — no    
node/cluster capacity problem otherwise (nodes show light actual usage, few     
mCPU/MB, per kubectl top pods).                                                 


                                      Fix                                       

Correct the worker Deployment's container CPU request back to millicores:       

                                                                                
 kubectl set resources deployment/worker -n shop --requests=cpu=50m -c worker   
                                                                                

or edit the Deployment and change resources.requests.cpu: "64" → "64m" (or back 
to 50m to match the previous working revision). Once applied, the new ReplicaSet
will roll out successfully and the old worker-6cf88d4b58-q9gtk pod will be      
terminated normally by the rollout.                                             
