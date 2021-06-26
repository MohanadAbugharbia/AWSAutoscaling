terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
}
variable "myregion" {
  type = string
  default = "eu-central-1"
}
provider "aws" {
  profile = "default"
  region  = var.myregion
}

# The min, max, and desired instance capacity to configure into the auto scaling group
variable "minSize_maxSize_desiredCapacity" {
    description = "The minimum size, maximum size, and desired capacity of ec2 instances to configure into the auto scaling group"
    type = list(number)
    default = [1,1,1]
}

variable "vpcCIDRblock" {
  default = "10.0.0.0/16"
}
variable "subnetCIDRblock" {
    description = "A list of CIDRs for each subnet"
    type = list(string)
    default = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}
variable "availabilityZones" {
    description = "A list of availability zones in which to create subnets"
    type = list(string)
    default = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "destinationCIDRblock" {
    type = string
    default = "0.0.0.0/0"   
}

# Pulls out an ami from the account that is running this code where the description is AWSAutoscaling
data "aws_ami" "ami_image_for_ec2_instances" {
    owners = [ "self" ]
    filter {
      name = "description"
      values = ["AWSAutoscaling"]
    }
}

# Outputs the dns name of the application load balancer
output "Application_load_balancer" {
    value = aws_lb.My_application_load_balancer.dns_name
}

# Getting the elb service account id for use in the s3 bucket policy
data "aws_elb_service_account" "main" {}

# create the VPC
resource "aws_vpc" "My_VPC" {
    cidr_block = var.vpcCIDRblock
    instance_tenancy = "default"
    enable_dns_support = "true"
    enable_dns_hostnames = "true"
    tags = {
        Name = "My VPC"
    }
}

# create the Subnets
resource "aws_subnet" "My_VPC_Subnet" {
  count = length(var.subnetCIDRblock)
    vpc_id = aws_vpc.My_VPC.id
    cidr_block = var.subnetCIDRblock[count.index]
    availability_zone = var.availabilityZones[count.index]
    tags = {
        Name = "Subnet ${var.availabilityZones[count.index]}"
    }
}

# Create an Internet Gateway
resource "aws_internet_gateway" "My_VPC_internet_gateway" {
    vpc_id = aws_vpc.My_VPC.id
    tags = {
        Name = "My VPC Internet Gateway"
    }
}

# Create a Route Table
resource "aws_route_table" "My_VPC_route_table" {
    vpc_id = aws_vpc.My_VPC.id
    tags = {
        Name = "My VPC Route Table"
    }
}

# Create internet access by routing requests going to the destinationCIDRblock (0.0.0.0/0) to the above created internet gateway
resource "aws_route" "My_VPC_route_for_internet_access" {
    count = length(var.subnetCIDRblock)
    route_table_id         = aws_route_table.My_VPC_route_table.id
    destination_cidr_block = var.destinationCIDRblock
    gateway_id             = aws_internet_gateway.My_VPC_internet_gateway.id
}

# Associate the Route Table with the Subnet
resource "aws_route_table_association" "My_VPC_route_rable_association" {
    count = length(var.subnetCIDRblock)
    subnet_id      = aws_subnet.My_VPC_Subnet[count.index].id
    route_table_id = aws_route_table.My_VPC_route_table.id
}

# Create the launch template
resource "aws_launch_template" "My_launch_template" {
    name = "My_launch_template"
    //image_id = var.image_id
    image_id = data.aws_ami.ami_image_for_ec2_instances.image_id
    instance_type = "t2.micro"
    key_name = "Key-pair-aws"
    instance_market_options {
        market_type = "spot"
    }
    network_interfaces {
        associate_public_ip_address = true
        security_groups = [aws_security_group.ec2_instance_security_group.id]
    }
}

# Create the Autoscaling group
resource "aws_autoscaling_group" "My_autoscaling_group" {
    name = "My_autoscaling_group"
    vpc_zone_identifier = [aws_subnet.My_VPC_Subnet[0].id, aws_subnet.My_VPC_Subnet[1].id, aws_subnet.My_VPC_Subnet[2].id]
    target_group_arns   = [aws_lb_target_group.My_target_group.arn]
    min_size            = var.minSize_maxSize_desiredCapacity[0]
    max_size            = var.minSize_maxSize_desiredCapacity[1]
    desired_capacity    = var.minSize_maxSize_desiredCapacity[2]
    launch_template {
        id      = aws_launch_template.My_launch_template.id
        version = "$Latest"
    }
    tags = [
        {
        "key"               = "Name"
        "value"             = "My_ASG_instance"
        propagate_at_launch = "true"
    }
    ]
}

# Create the application load balancer's target group
resource "aws_lb_target_group" "My_target_group" {
    name     = "My-target-group"
    port     = 80
    protocol = "HTTP"
    vpc_id   = aws_vpc.My_VPC.id
    health_check {
        enabled             = "true"
        healthy_threshold   = 5
        interval            = 10
        path                = "/"
        port                = 80
        protocol            = "HTTP"
        timeout             = 2
        unhealthy_threshold = 5
    }
    tags = {
        Name = "My_target_group"
    }
}

# Create the application load balancer
resource "aws_lb" "My_application_load_balancer" {
    name               = "My-application-load-balancer"
    internal           = false
    load_balancer_type = "application"
    security_groups    = [aws_security_group.application_load_balancer_security_group.id]
    subnets            = [aws_subnet.My_VPC_Subnet[0].id, aws_subnet.My_VPC_Subnet[1].id, aws_subnet.My_VPC_Subnet[2].id]

    access_logs {
        bucket  = aws_s3_bucket.application_load_balancer_logs.bucket
        prefix  = "My_application_load_balancer_logs"
        enabled = true
    }

    tags = {
        Name = "My_application_load_balancer"
    }
    depends_on = [
        aws_s3_bucket_policy.My_ALB_logs_bucket_policy
    ]
}

# Create an ALB listener
resource "aws_lb_listener" "My_application_load_balancer_port80_listener" {
    load_balancer_arn = aws_lb.My_application_load_balancer.id
    port              = 80
    default_action {
        target_group_arn = aws_lb_target_group.My_target_group.id
        type             = "forward"
    }
}

# Creating an s3 bucket for the ALB logs
resource "aws_s3_bucket" "application_load_balancer_logs" {
    bucket        = "mohanad-application-load-balancer-logs"
    acl           = "private"
    force_destroy = true
    tags = {
        Name = "application_load_balancer_logs"
  }
}

# Blocking public acces on the s3 bucket
resource "aws_s3_bucket_public_access_block" "s3_bucket_application_load_balancer_logs" {
    bucket = aws_s3_bucket.application_load_balancer_logs.id

    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
    depends_on = [
        aws_s3_bucket.application_load_balancer_logs
    ]
}

# Creating a bucket policy to allow the ALB to log into the s3 bucket
resource "aws_s3_bucket_policy" "My_ALB_logs_bucket_policy"{
    bucket = aws_s3_bucket.application_load_balancer_logs.id
    policy = jsonencode(
{
    "Version": "2012-10-17",
    "Id": "Policy1624008311279",
    "Statement": [
        {
            "Sid": "Stmt1624007980607",
            "Effect": "Allow",
            "Principal": {
                "AWS": data.aws_elb_service_account.main.arn
            },
            "Action": "s3:PutObject",
            "Resource": "${aws_s3_bucket.application_load_balancer_logs.arn}/*"
        }
    ]
})
    depends_on = [
        aws_s3_bucket_public_access_block.s3_bucket_application_load_balancer_logs
    ]
}

# Creating security groups
resource "aws_security_group" "application_load_balancer_security_group" {
    name        = "ALB_SG"
    vpc_id      = aws_vpc.My_VPC.id
    ingress {
        description      = "Allow http from everywhere"
        from_port        = 80
        to_port          = 80
        protocol         = "tcp"
        cidr_blocks      = ["0.0.0.0/0"]
    }
    egress {
        description = "Allow http to everywhere"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        Name = "ALB_SG"
    }
}
resource "aws_security_group" "ec2_instance_security_group" {
    name = "ec2_SG"
    vpc_id = aws_vpc.My_VPC.id
    ingress {
        description     = "Allow http from the load balancer"
        from_port       = 80
        to_port         = 80
        protocol        = "tcp"
        security_groups = [aws_security_group.application_load_balancer_security_group.id]
    }
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    tags = {
        Name = "ec2_SG"
    }
}