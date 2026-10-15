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
Lazily initializing toolset bash...                                             
✅ Toolset bash                                                                 
Running tool #1 bash: kubectl get deployment frontend -n shop -o wide; echo ---;
kubectl describe deployment frontend -n shop; echo ---; kubectl get rs -n shop  
-l app=frontend -o wide                                                         
Executing bash command: kubectl get deployment frontend -n shop -o wide; echo   
---; kubectl describe deployment frontend -n shop; echo ---; kubectl get rs -n  
shop -l app=frontend -o wide                                                    
  Finished #1 in 0.13s, output length: 2,425 characters (53 lines) - /show 1 to 
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
Running tool #2 bash: kubectl get pods -n shop -l app=frontend -o wide; echo    
---; kubectl describe pod -n shop -l pod-template-hash=7b6c998456 | tail -40    
Executing bash command: kubectl get pods -n shop -l app=frontend -o wide; echo  
---; kubectl describe pod -n shop -l pod-template-hash=7b6c998456 | tail -40    
  Finished #2 in 0.09s, output length: 2,965 characters (46 lines) - /show 2 to 
view contents                                                                   
The AI requested 1 tool call(s).                                                
                                                                                
AI: Root cause confirmed: typo in container image tag.                              

What changed: Deployment frontend (namespace shop) was updated to revision 2    
(deployment.kubernetes.io/revision: 2) ~75s ago, changing the image tag from    
nginx:1.27-alpine → nginx:1.27-alpne (missing the "i"). This created new        
ReplicaSet frontend-7b6c998456.                                                 

Why rollout is stuck: The new pod frontend-7b6c998456-rv848 can't pull the      
misspelled tag:                                                                 

                                                                                
 Failed to pull image "nginx:1.27-alpne": ... not found                         
 Error: ErrImagePull → ImagePullBackOff                                         
                                                                                

Since maxUnavailable: 25% on 2 replicas, the rolling update can't proceed past  
1/2 new pods ready, so the deployment sits at 1 updated, 2 total available (via 
old RS), 1 unavailable.                                                         

 • Old RS frontend-76d98597b9 (image nginx:1.27-alpine, correct): 2/2 pods      
   Running/Ready — still serving traffic, so no outage.                         
 • New RS frontend-7b6c998456 (image nginx:1.27-alpne, typo'd): 0/1 ready, stuck
   in ImagePullBackOff.                                                         

Fix: correct the image tag back to nginx:1.27-alpine:                           

                                                                                
 kubectl set image deployment/frontend nginx=nginx:1.27-alpine -n shop          
                                                                                

or edit the deployment spec and reapply. This will let the rollout complete; the
old RS will scale down once the new pods become ready.                          
