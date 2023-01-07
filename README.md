<!--
Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction, including without limitation the rights to use, copy, modify,
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-->

# Building a Cloud in the Cloud: Running Apache CloudStack on Amazon EC2

## Intro
This is a collection of AWS CloudFormation templates and bash scripts that demonstrate ways to run Apache CloudStack on Amazon Elastic Compute Cloud (Amazon EC2).  The reasons for the scripts are explained in their corresponding blog posts.  Read more about [the simple way](https://aws.amazon.com/blogs/compute/building-a-cloud-in-the-cloud-running-apache-cloudstack-on-amazon-ec2-part-1/) and [the scalable way](https://aws.amazon.com/blogs/compute/building-a-cloud-in-the-cloud-running-apache-cloudstack-on-amazon-ec2-part-2/).

## Prereqs
CentOS 7 -- The [Official CentOS 7 x86_64 HVM image](https://aws.amazon.com/marketplace/pp/B08KYKK42V) works well.  If you use a different image, you might run into issues with firewalls or NetworkManager.  If you're using a different version or flavor of Linux, you'll likely need to customize these scripts.

Virtual Private Cloud (Amazon VPC) -- You'll need a VPC with DNS resolution and DNS hostnames enabled.

Subnets -- Depending on the template you choose, you'll need either one or two private subnets.  The subnet chosen for CloudStack needs to allow outbound Internet access.

## Security
The intent behind these scripts is to demonstrate ways to run Apache CloudStack on Amazon EC2.  They are not intended as a demonstration of security best practices.  Please refer to the [CloudStack Installation Guide](https://docs.cloudstack.apache.org/en/latest/installguide/index.html) and [AWS documentation](https://docs.aws.amazon.com/) for more information on security.

Be aware that the installation scripts disable SELinux on the host instances.  This is a
[CloudStack requirement](https://docs.cloudstack.apache.org/en/latest/installguide/hypervisor/kvm.html#configure-the-security-policies).

## Cost
The CloudFormation templates create resources that have costs associated with them, including bare metal EC2 instances, EFS file systems, and RDS databases.  You will be billed for the resources used.

## EC2 Instance Types
The CloudFormation templates were created with simplicity in mind.  They don't include full lists of every instance type that would work.  You can customize the templates to add more instances types.  Keep in mind that instances running CloudStack software need to use the x86_64 architecture, and the hypervisor hosts need to be bare metal instances.  And only Nitro instance types can be used with the scalable way.  Please refer to the above mentioned blog posts to learn more.

## CloudStack Versions
Everything was tested with CloudStack 4.17, but should also work with 4.16.

The configure_cloudstack_demo.sh script relies on key authentication for CloudStack to configure the host.  This feature was added to CloudStack in version 4.16.  If you're not using this script, you might be able to use older 4.x versions.

## The Simple Way
This approach puts everything on a single EC2 instance.  It's not very scalable, but it's easy.  Use the [simple_way_demo.yaml](simple_way_demo.yaml) CloudFormation template to set up a demonstration environment.

Decide on an IP address range to use for the virtual subnet.  It shouldn't conflict with other subnets in your VPC.  In the template parameters, you can specify the IP range, along with the address from that range that will be given to the CloudStack EC2 instance.

The template will create an EC2 instance (CentOS 7 on bare metal) that serves as a management server, a hypervisor, a database server, a file server, and a router.  CloudStack and its VMs will connect to the virtual subnet, which exists inside the EC2 instance.

The instance will act as a router between the virtual subnet and your AWS VPC.  After the EC2 instance is created, you'll need to manually upate your AWS route tables.  Add routes using the virtual subnet as the destination, and the CloudStack EC2 instance as the target.  It's up to you to decide which route tables to update, depending on which resources should have access to CloudStack.

## The Scalable Way
This approach creates three EC2 instances: a CloudStack management server (CentOS 7), a CloudStack host (CentOS 7 on bare metal), and a router (Amazon Linux 2).  All three instancees are connected by an overlay network.  The router connects the overlay network to your AWS VPC.  An RDS database and an EFS file system will be created for CloudStack to use for storage.

Use the [scalable_way_demo.yaml](scalable_way_demo.yaml) CloudFormation template to set up a demonstration environment.

Decide on an IP address range to use for the overlay network.  It shouldn't conflict with other subnets in your VPC.  In the template parameters, you can specify the IP range, along with the addresses from that range that will be given to the EC2 instances.

After the stack is created, you'll need to manually update your AWS route tables.  Add routes using the overlay network as the destination, and the router EC2 instance as the target.  It's up to you to decide which route tables to update, depending on which resources should have access to CloudStack.

Make sure the route table for the local subnet gets one of these routes, too.  Until that route gets added, CloudStack's secondary storage VM won't be able to connect to EFS.  And that means it won't be able to download any VM templates.  The storage VM may give up and stop trying after a short time.  If you've added the route and CloudStack still isn't downloading VM templates, restart the storage VM in the CloudStack UI.

## Access Location
For security reasons, you'll need to specify an access location.  This is a IP address range in your VPC that will have access to CloudStack and its VMs.  The range must be in CIDR notation, with a suffix of /16 or higher.  After you configure your AWS route tables appropriately, the CloudStack environment and the access location will be able to access each other via a router.  In the simple way, the router is the same EC2 instance that's running CloudStack.  In the scalable way, the router is a dedicated EC2 instance that's created along with the CloudStack instances.

When a CloudStack instance or VM contacts an address that's outside the virtual subnet or overlay network, and also outside the access location, the router will use NAT.  This helps ensure that the installation scripts can download the needed software before you've had a chance to modify the route tables.

## Accessing the CloudStack UI
The simplest way to access the CloudStack UI is using an SSH tunnel.  You'll need a bastion instance in a public subnet, and the public subnet will need a route to the CloudStack virtual subnet or overlay network.  Connect to the bastion host using `ssh -i <path to key file> ec2-user@<bastion public address> -L 8080:<CloudStack management address>:8080`, then point your web browser to `http://localhost:8080/client/`.  The console viewer won't work if you connect using an SSH tunnel, but everything else in the UI should be functional.

For a more complete solution, you can use an AWS Client VPN to connect to your VPC.  As long as your VPN makes it appear that you're in the access location IP range, you'll have all the functionality of the UI, including the console viewer.  You'll also be able to connect directly to VMs that are using a CloudStack shared network, and any load balanacers that you create for isolated networks.

The default username is `admin`, and the default password is `password`.

## Accessing the CloudStack Servers Using SSH
If you're doing things the simple way, you would have provided your own key pair.  You can SSH to the instance using your public key.  The username is `centos`.

If you're doing things the scalable way, you'll need to retrieve the private key from AWS before you can use SSH.  The CloudFormation output includes a command you can run to get the private key using the AWS CLI.  You can also look up the key in the Systems Manager Parameter Store.  The username for the router is `ec2-user`.  The username for the management and host instances is `centos`.
