output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Hit http://<this>/ or http://<this>/health"
  value       = aws_lb.backend_alb.dns_name
}

output "target_group_arn" {
  description = "ARN of the backend Target Group"
  value       = aws_lb_target_group.backend_tg.arn
}

output "autoscaling_group_name" {
  description = "Name of the backend Auto Scaling Group"
  value       = aws_autoscaling_group.backend_asg.name
}

output "launch_template_id" {
  description = "ID of the backend Launch Template"
  value       = aws_launch_template.backend_lt.id
}