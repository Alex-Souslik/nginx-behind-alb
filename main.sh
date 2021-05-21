#!/usr/bin/bash

set -xe # e-exit on error, x-show executed command

# objects created by script #
colors=(red blue) # requeired colors
alb_name='alex-alb' # name of to be created LB

# objects already existing #
bucket='alex-static-files' # contains color folders with html files
image_id='ami-077e31c4939f6a2f3' # Amazon Linux 2 x86_64
i_profile='EC2' # has AmazonS3ReadOnlyAccess policy
i_type='t2.micro' # the free one
vpc='vpc-20d3404b' # default vpc
subnets=(subnet-bdcb70d6 subnet-b5c990f9) # exist, subnet count >= color count
sg='sg-090bfb19d9d949429' # allows inbound port 80 from 0.0.0.0

generate_listener_default_action() {
(cat <<EOF
[
    {
        "Type": "fixed-response",
        "Order": 1,
        "FixedResponseConfig": {
            "MessageBody": "/red OR /blue",
            "StatusCode": "200",
            "ContentType": "text/plain"
        }
    }
]
EOF
) > listener-default.json # End Of File
}

generate_user_data() {
(cat <<EOEF
#!/bin/bash
amazon-linux-extras install nginx1
mkdir -p /usr/share/nginx/html/$1/
aws s3 cp s3://$bucket/$1/$1.html /usr/share/nginx/html/$1/$1.html
cat <<EOIF > /etc/nginx/nginx.conf
worker_processes  1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    
    server {
        listen       80;
        server_name  _;
        root   /usr/share/nginx/html;
        index  index.html;
        location /$1/ {
            try_files \\\$uri /$1/$1.html;
        }
    }
}
EOIF
systemctl enable --now nginx
EOEF
) > $1.sh # End Of External File
}

loadbalancer=`aws elbv2 create-load-balancer --name $alb_name --security-groups $sg \
    --subnets ${subnets[@]} | jq -r '.LoadBalancers[].LoadBalancerArn'`
generate_listener_default_action # create listener-default.json
listener=`aws elbv2 create-listener --load-balancer-arn $loadbalancer --protocol HTTP --port 80 \
    --default-actions file://listener-default.json  | jq -r '.Listeners[].ListenerArn'`
rm -f listener-default.json #done with listener-default.json

for (( i=0; i<=${#color[@]}; i++ )); do # creation loop
    generate_user_data ${colors[$i]}  # create user-data script per color
    targetgroups+=(`aws elbv2 create-target-group --name ${colors[$i]} --protocol HTTP --port 80 \
        --vpc-id $vpc | jq -r '.TargetGroups[].TargetGroupArn'`) # create tg per color
    instances+=(`aws ec2 run-instances  --instance-type $i_type --count 1 --image-id $image_id \
        --iam-instance-profile Name="$i_profile"  --security-group-ids $sg --user-data file://${colors[$i]}.sh  \
        --subnet-id ${subnets[$i]} --key-name nginxKey | jq -r '.Instances[].InstanceId'`)  # each instance will be in a different subnet
    states+=(`aws ec2 describe-instance-status --instance-id ${instances[$i]} | jq -r '.InstanceStatuses[].InstanceState.Name'`)
    rm -f ${colors[$i]}.sh # done with user-data script
done

for (( i=0; i<=${#color[@]}; i++ )); do # assigment loop
    while [[ ${states[$i]} != 'running' ]]; do
        sleep 10s # can't register instance before it's running
        states[$i]=`aws ec2 describe-instance-status --instance-id ${instances[$i]} | jq -r '.InstanceStatuses[].InstanceState.Name'`
    done # each instance will be in a the appropriate tg
    aws elbv2 register-targets --target-group-arn ${targetgroups[$i]} --targets Id=${instances[$i]} # register each instance to its tg
    (( priority=($i+1)*10 )) # listener-rule priority
    aws elbv2 create-rule --listener-arn $listener --priority $priority --conditions Field=path-pattern,Values="/${colors[$i]}*" \
        --actions Type=forward,TargetGroupArn=${targetgroups[$i]} # rule per color tg
done