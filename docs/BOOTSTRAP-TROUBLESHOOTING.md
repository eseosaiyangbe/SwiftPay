# EKS Bootstrap Node Troubleshooting

> **Navigation:** General failures → [TROUBLESHOOTING.md](../TROUBLESHOOTING.md). Infra order → [INFRASTRUCTURE-ONBOARDING.md](INFRASTRUCTURE-ONBOARDING.md). Full index → [Documentation index](README.md).

The EKS stack uses a **one-off bootstrap EC2 instance** that installs Helm add-ons (ALB controller, External Secrets, Cluster Autoscaler, etc.) and then terminates itself. If that script fails mid-way, the instance **does not self-terminate** and Terraform will not re-run bootstrap on the next apply (the instance already exists).

## Symptom: Ingress stuck in `Pending`

- You ran `terraform apply` for the spoke-vpc-eks module.
- The Ingress resource never gets an external hostname / ALB address.
- `kubectl get ingress -n swiftpay` shows `ADDRESS` empty or `<pending>`.

**Likely cause:** The bootstrap script failed (e.g. Helm timeout, IRSA not propagated yet, spot interruption). The bootstrap instance is still running, so Terraform does not create a new one on re-apply.

## What to do

1. **Get the bootstrap instance ID**
   - Terraform output: `terraform output bootstrap_instance_id`
   - Or AWS Console: EC2 → Instances → filter by name containing `bootstrap`.

2. **Check bootstrap logs**
   - SSM Session Manager (if the instance has SSM agent and IAM):
     ```bash
     aws ssm start-session --target <bootstrap-instance-id> --region <region>
     sudo tail -n 500 /var/log/bootstrap.log
     ```
   - Or attach the instance to a security group that allows your IP on 22 and use SSH (if you have the key).

3. **Terminate the instance**
   - AWS Console: EC2 → select instance → Instance state → Terminate.
   - Or CLI: `aws ec2 terminate-instances --instance-ids <id> --region <region>`

4. **Re-run Terraform**
   - `terraform apply` again. Terraform will see the bootstrap instance is gone and create a new one; the new instance will run the script from scratch.

5. **Wait for bootstrap to finish**
   - The new instance runs `bootstrap.sh`; it installs Helm charts with `--wait`. If it completes, it self-terminates. Check that the instance goes to "terminated" and that the ALB controller and other add-ons are installed: `kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`.

## Why there is no automatic retry

The bootstrap is implemented as a single EC2 instance with `user_data`. Terraform has no visibility into whether the script succeeded or failed. Making the script fully idempotent (so re-running on the same instance is safe) would require either:

- Moving bootstrap into a separate pipeline (e.g. CI job or Lambda) that checks cluster state and re-runs only when needed, or
- Making every step in `bootstrap.sh` idempotent and having the instance retry on failure (e.g. loop until Helm succeeds, then self-terminate).

Until then, the operational fix is: **if Ingress is Pending, assume bootstrap failed → check logs on the bootstrap instance → terminate instance → re-apply.**

## References

- Bootstrap module: `terraform/aws/spoke-vpc-eks/modules/bootstrap-node/`
- Script: `terraform/aws/spoke-vpc-eks/modules/bootstrap-node/templates/bootstrap.sh`
- Inline comment in Terraform: `terraform/aws/spoke-vpc-eks/bootstrap.tf` (“If bootstrap fails…”)
