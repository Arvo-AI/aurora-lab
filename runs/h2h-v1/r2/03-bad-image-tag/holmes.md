Interactive mode disabled when reading piped input
Model 'bedrock/us.anthropic.claude-sonnet-5' has no entry in litellm's cost map 
and no input/output_cost_per_token configured. Usage event costs for this model 
will be 0. Add input_cost_per_token and output_cost_per_token to its            
model_list.yaml entry to enable cost tracking.                                  
Loaded models: ['bedrock/us.anthropic.claude-sonnet-5']                         
User: KubeDeploymentRolloutStuck: deployment frontend in namespace shop has not 
progressed. Namespace shop, cluster kind-aurora-lab. Find the root cause and say
what changed.
Using selected model: bedrock/us.anthropic.claude-sonnet-5                      
Model: bedrock/us.anthropic.claude-sonnet-5, 1M context, 120K max response      
(default, change with --model, for all options see                              
https://holmesgpt.dev/ai-providers)                                             
Using 28 datasources (toolsets). To refresh: use flag `--refresh-toolsets`      
Lazily initializing toolset kubernetes/core...                                  
✅ Toolset kubernetes/core                                                      
Running tool #1 kubernetes_jq_query: jq query: kubectl get deployments | jq     
''.items[] | select(.metadata.namespace=="shop" and .metadata.name=="frontend") 
| {name:.metadata.name, generation:.metadata.generation,                        
observedGeneration:.status.observedGeneration, replicas:.status.replicas,       
updated:.status.updatedReplicas, available:.status.availableReplicas,           
unavailable:.status.unavailableReplicas, conditions:.status.conditions,         
strategy:.spec.strategy}''                                                      
Running tool #2 kubernetes_tabular_query: filter: kubectl get pods              
columns=''NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatus
es[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,REASON:.status.co
ntainerStatuses[0].state.waiting.reason'' filter=frontend                       
  Finished #2 in 0.42s, output length: 444 characters (10 lines) - /show 2 to   
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #1 in 0.49s, output length: 1,063 characters (41 lines) - /show 1 to 
view contents                                                                   
                                                                                
Running tool #3 kubernetes_jq_query: jq query: kubectl get replicasets | jq     
''.items[] | select(.metadata.namespace=="shop" and                             
(.metadata.name|startswith("frontend"))) | {name:.metadata.name,                
replicas:.spec.replicas, image:.spec.template.spec.containers[0].image,         
podTemplateHash:.metadata.labels["pod-template-hash"],                          
createdAt:.metadata.creationTimestamp}''                                        
Running tool #4 kubernetes_jq_query: jq query: kubectl get pods | jq ''.items[] 
| select(.metadata.namespace=="shop" and                                        
.metadata.name=="frontend-7b6c998456-8s5ht") | {name:.metadata.name,            
image:.spec.containers[0].image, events: .status.containerStatuses}''           
  Finished #3 in 0.32s, output length: 466 characters (21 lines) - /show 3 to   
view contents                                                                   
The AI requested 2 tool call(s).                                                
  Finished #4 in 0.33s, output length: 1,228 characters (40 lines) - /show 4 to 
view contents                                                                   
                                                                                
AI: Found it: typo in the image tag.                                                

Root cause: Deployment frontend (namespace shop) was updated to generation 2 at 
2026-10-16T08:03:03Z with container image nginx:1.27-alpne — a typo, should be  
nginx:1.27-alpine. The new ReplicaSet frontend-7b6c998456 created pod           
frontend-7b6c998456-8s5ht, which is stuck Pending/ImagePullBackOff:             

                                                                                
 Back-off pulling image "nginx:1.27-alpne": ErrImagePull: ... failed to resolve 
 reference                                                                      
 "docker.io/library/nginx:1.27-alpne": docker.io/library/nginx:1.27-alpne: not  
 found                                                                          
                                                                                

What changed: Someone/something edited the deployment's pod template image tag  
from nginx:1.27-alpine (old ReplicaSet frontend-76d98597b9, still running 2/2   
healthy pods) to the misspelled nginx:1.27-alpne (new ReplicaSet                
frontend-7b6c998456). Since maxUnavailable: 25%, the rollout can't fully proceed
— it's stuck with 2 old pods available + 1 new pod failing to pull, matching the
KubeDeploymentRolloutStuck alert (Progressing=True, reason=ReplicaSetUpdated but
not completing).                                                                

Fix: Correct the image tag back to nginx:1.27-alpine:                           

                                                                                
 kubectl set image deployment/frontend nginx=nginx:1.27-alpine -n shop          
                                                                                

or edit the deployment spec directly. This will let the rollout proceed and the 
old ReplicaSet will scale down once the new pods become healthy.                
