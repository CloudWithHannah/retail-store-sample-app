<div align="center">
<strong>
<h2>✨ Project Bedrock: InnovateMart's Store on AWS EKS ✨</h2>
</strong>
</div>

Hello! 👋 Welcome to Project Bedrock! This project was all about building a super cool home on Amazon Web Services (AWS) for InnovateMart's brand new online store. Think of it like setting up a fancy, high tech stage and backstage for a really popular online shop.

**The Big Goal:** To take the `retail-store-sample-app` (which is like a puzzle made of many small app pieces called microservices) and get it running smoothly on AWS's special service for running apps like this, called EKS (Elastic Kubernetes Service).

**Who Did This Magic?** This setup was built with lots of care (and maybe a little late night coffee!) by a Cloud DevOps Engineer at InnovateMart. ☕

**🎉 See it LIVE! 🎉:** https://bedrock.ngozi-opara-portfolio.com

---

### What Super Tools Did We Use? 🛠️

* **AWS CloudFormation:** Our magic wand for building things on AWS! Instead of clicking lots of buttons, we wrote instructions (like blueprints) in files (`.yaml`). AWS reads these and builds exactly what we described. This keeps everything organized and repeatable.
* **AWS EKS (Elastic Kubernetes Service):** The main stage for our app! It's an AWS service that's amazing at managing apps made of many small parts. It makes sure all the pieces work together, stay healthy, and can handle lots of visitors. It's like the show's director!
* **Kubernetes (kubectl):** Our remote control for talking to EKS. We use this command line tool to tell EKS what to run, check on things, and manage the app.
* **Helm & Helmfile:** These are like special app installers just for Kubernetes. The sample store app came packaged this way, so we learned how to use `helmfile` to install everything easily. 📦
* **Docker:** Each little piece of the app (microservice) is put into its own "Docker container" box. This makes sure it runs the same way everywhere. EKS is great at running these boxes.
* **AWS CLI:** A way to talk to AWS using typed commands in the terminal, like a secret code language for AWS pros!
* **GitHub Actions:** Our trusty robot assistant living in GitHub! It automatically takes our CloudFormation blueprints and tells AWS to build or update things whenever we save our code. Super helpful for automation! 🤖
* **AWS Load Balancer Controller (LBC), ACM & Route 53:** Our team for connecting the app safely to the internet!
    * The **LBC** creates a smart traffic director (Application Load Balancer - ALB).
    * **ACM** (AWS Certificate Manager) gives us a free SSL certificate (the padlock 🔒 that means HTTPS is working).
    * **Route 53** is like the internet's address book, pointing our website name to the Load Balancer.

---

### How Our Project Folder is Organized 📁

Keeping things tidy is important! Here's where you can find everything:

* `Project-Bedrock-Core.yaml`: The CloudFormation blueprint for our main network (VPC) and the important security guards (IAM Roles) for EKS.
* `EKS_Cluster.yaml`: The CloudFormation blueprint for the EKS cluster brain and its worker computers (Nodes).
* `k8s/`: A special folder just for instructions we give directly to Kubernetes.
    * `rbac/`: Holds files about permissions – who gets to do what.
        * `read-only-role.yaml`: The list of rules for developers who can only look.
        * `read-only-binding.yaml`: Connects the rules to the developers' group.
    * `ingress.yaml`: Instructions for creating the internet traffic director (Load Balancer).
* `.github/workflows/`: Holds the instructions for our GitHub Actions robot.
    * `deploy-infra.yml`: The steps to automatically run our CloudFormation blueprints.
* `README.md`: You are here! Reading this awesome file. 😊

---

### The Original App's Architecture 🏗️

The sample app itself is made of many pieces, designed to show off different technologies:

| Component | Language | Container Image | Helm Chart | Description |
| :--- | :--- | :--- | :--- | :--- |
| UI | Java | Link | Link | Store user interface |
| Catalog | Go | Link | Link | Product catalog API |
| Cart | Java | Link | Link | User shopping carts API |
| Orders | Java | Link | Link | User orders API |
| Checkout | Node | Link | Link | API to manage checkout process |

(Note: For our project, we focused on deploying these, not changing their code!)

---

### Our Adventure: Building Project Bedrock Step-by-Step 🗺️

Building this was a journey with lots of learning! Here's how we did it:

#### Phase 1 & 2: Building the Foundation (The "Stage") 🏗️

* **Goal:** Create the basic home (network and cluster) on AWS using CloudFormation blueprints.
* **How:**
    * Used `Project-Bedrock-Core.yaml` to build the VPC (our private land), including public spots, private spots, internet gates (IGW), special doors for private spots (NAT Gateways), and traffic rules (Route Tables). It also created the first security guards (IAM Roles) EKS needs.
    * Used `EKS_Cluster.yaml` to build the EKS cluster (the brain) and the worker computers (Nodes) that actually run the app boxes (containers).
* **Why two blueprints?** Keeps the network stuff separate from the cluster stuff. Nice and clean!

#### Phase 3: Connecting to the Cluster 🔌

* **Goal:** Make sure our own computer could talk to the new EKS brain.
* **How:** Installed `kubectl` (the remote control) and ran `aws eks update-kubeconfig` to teach `kubectl` the secret handshake to connect.
* **Oops! Troubleshooting Time! 😅** We hit some bumps:
    * `kubectl: command not found`: Our computer forgot where `kubectl` lived! We fixed its address book (the PATH).
    * `Access Denied / i/o timeout`: This was tricky!
        * First, we were accidentally telling `kubectl` the wrong cluster name! We fixed it by running `aws eks update-kubeconfig` with the right name (`Project-Bedrock-EKSCluster`). Phew!
        * Then, our computer's network got confused (a common thing with WSL 1). We manually told it to use Google's reliable address book (`8.8.8.8`) in `/etc/resolv.conf`. We even made this fix permanent by editing `/etc/wsl.conf` and restarting WSL (`wsl --shutdown`).

#### Phase 4: Deploying the InnovateMart App 🚀

* **Goal:** Get the online store running inside EKS.
* **How:** The instructions first said `kubectl apply`, but we looked closer and saw the app used Helm Charts (fancy app packages). So we switched plans!
    * Installed `helm` and `helmfile` (the Kubernetes app installers).
    * Ran `helmfile sync`. This command was super smart! It read the app's instructions and automatically installed all the different parts (ui, cart, etc.) and even started up the simple databases inside the cluster for this first setup.
* **Oops! Troubleshooting Time! 😅**
    * `kubectl apply` didn't work because it's not for Helm charts. Lesson learned!
    * Installing `helmfile` on WSL 1 was a mini adventure. `snap` didn't work, `apt` didn't work. We had to download it directly using `curl`, make sure we got the real program (not an error page!), make it runnable (`chmod +x`), and move it (`sudo mv`) to a place our computer always looks (`/usr/local/bin`).

#### Phase 5: Giving Developers Read Only Access 👀

* **Goal:** Let developers peek inside the cluster (check logs, see what's running) without letting them accidentally break anything.
* **How:** A two part plan!
    * **AWS Part:** Added a new user (`ReadOnlyDevUser`) to the `EKS_Cluster.yaml` blueprint. This user has AWS keys but zero powers in AWS itself.
    * **Kubernetes Part:** Taught Kubernetes about this user.
        * Edited the `aws-auth ConfigMap` (the EKS guest list) to add the `ReadOnlyDevUser`'s AWS ID (ARN) and put them in a special group `read-only-group`.
        * Created the `k8s/rbac/read-only-role.yaml` file (the rulebook saying "only viewing allowed").
        * Created the `k8s/rbac/read-only-binding.yaml` file (giving the rulebook to the `read-only-group`).
        * Applied both files with `kubectl apply`.

#### Phase 6: Automating the Blueprints (CI/CD) 🤖

* **Goal:** Make GitHub Actions automatically update our AWS setup when we save code.
* **How:**
    * Saved our AWS keys super securely in GitHub Secrets. No keys in the code!
    * Created the `.github/workflows/deploy-infra.yml` file.
    * This file tells GitHub: When code is pushed, check it out, use the secret keys, and run `aws cloudformation deploy`. If it's just a test branch (`feature/*`), make a plan (`--no-execute-changeset`). If it's the main branch (`main`), apply the changes for real!

#### Phase 7: Using Fancy AWS Databases (Bonus - Skipped) 💾

* **Goal:** Swap the simple databases inside EKS for powerful, separate AWS database services (RDS, DynamoDB). This makes the app more robust.
* **Status:** We skipped this because we were running out of time for the deadline! ⏳
* **How it would work:** Add RDS/DynamoDB to the `Project-Bedrock-Core.yaml` blueprint. Change the app's Kubernetes settings (`Secrets`/`ConfigMaps`) to point to the new database addresses. Use AWS Secrets Manager to handle passwords safely.

#### Phase 8: Secure Internet Access (Bonus - Completed!) 🌐🔒

* **Goal:** Put the app online securely with HTTPS.
* **How:**
    * **EKS OIDC:** Turned on a security feature so EKS could talk to AWS IAM safely.
    * **LBC IAM Role:** Created a special security guard (IAM Role) just for the Load Balancer software. We did this manually in the AWS Console because we hit some snags with CloudFormation earlier. We named the Role `ProjectBedrock-LBC-Policy` (a bit confusing, we know!) and attached the `lbc-policy` permissions to it.
    * **SSL Certificate:** Got a FREE padlock (SSL Certificate) from AWS Certificate Manager (ACM) for our website name `bedrock.ngozi-opara-portfolio.com`. We proved we owned it using DNS validation (adding a special CNAME record in Route 53).
    * **Installed Controller:** Used `helm` to install the AWS Load Balancer Controller software into EKS, telling it to use the IAM Role we created.
    * **Created Ingress:** Made the `k8s/ingress.yaml` file. This tells the controller: Build a public Load Balancer (ALB), use our SSL certificate, listen on ports 80/443, redirect HTTP to HTTPS, and send traffic for our website name to the `ui` part of our app. Applied it with `kubectl apply`.
    * **Pointed the Domain:** Waited for the Load Balancer to be built, got its unique AWS web address, and went to Route 53 to create an A (Alias) record, pointing `bedrock.ngozi-opara-portfolio.com` straight to the Load Balancer.
* **MAJOR Troubleshooting! 🤯** This was the trickiest part!
    * **Load Balancer Address Never Appeared:** The `kubectl get ingress` command just wouldn't show an address. Why?
        * **Problem:** The controller couldn't "wear" its IAM Role (`sts:AssumeRoleWithWebIdentity` errors).
        * **Fix:** The Trust Policy JSON on the IAM Role in the console had typos! We carefully fixed the JSON to correctly trust the EKS OIDC provider and check for the right `aud` and `sub` conditions.
        * **Problem:** The controller's "Service Account" inside Kubernetes pointed to the wrong Role name!
        * **Fix:** A diagnostic script found this and ran `kubectl annotate` to fix the pointer. Success!
        * **Problem:** The controller didn't know where to build the ALB! Our public network spots (subnets) were missing special AWS tags.
        * **Fix:** The diagnostic script found this and ran `aws ec2 create-tags` to add the `kubernetes.io/role/elb` tag. Hooray!
        * **Problem:** Still getting `AccessDenied` in the controller's logs! The script showed the pods weren't even getting the chance to use the role (missing `AWS_WEB_IDENTITY_TOKEN_FILE`).
        * **Fix:** We restarted the controller pods (`kubectl rollout restart deployment`). This allowed them to start fresh and pick up all the corrected settings (like the Service Account annotation).
        * **Problem:** New `AccessDenied` errors! The controller could now wear the role, but the role didn't have enough powers! The permissions policy (`lbc-policy`) was missing `AddTags` and `DescribeListenerAttributes`.
        * **Fix:** We edited the `lbc-policy` JSON in the IAM console, adding the missing permissions, and restarted the pods one last time. FINALLY, IT WORKED! 🎉
    * **"Not Secure" Warning:** After it worked, the browser complained. We added the `listen-ports` and `actions.ssl-redirect` instructions to `k8s/ingress.yaml` and re-applied it (`kubectl apply`). Secure now! ✅

---

### How to Visit the Live App 🤩

You can see the InnovateMart store running securely here:
**https://bedrock.ngozi-opara-portfolio.com**

---

### How Developers Can Get Read Only Access 🕵️‍♀️

We made a special AWS user (`ReadOnlyDevUser`) so developers can safely look around inside the cluster. Here's how they set it up:

1.  **Get Secret Keys:** They need the `ReadOnlyDevUserAccessKey` and `ReadOnlyDevUserSecretKey`. These are in the CloudFormation outputs for the `Bedrock-cluster` stack on the AWS website. (Share these secretly!)
2.  **Setup AWS Keys:** Open a terminal and run this command. Enter the keys, region (`eu-north-1`), and format (`json`) when asked.
    ```bash
    aws configure --profile readonly-dev
    ```
    (The `--profile readonly-dev` nickname keeps these keys separate).
3.  **Connect to Kubernetes:** Run this command to teach `kubectl` how to connect using the read only keys:
    ```bash
    aws eks update-kubeconfig --name Project-Bedrock-EKSCluster --region eu-north-1 --profile readonly-dev
    ```
4.  **Ready to Explore!** Now they can use commands like `kubectl get pods` to look, but not `kubectl delete` to change things. Safety first!

---

### What Could Be Next? (Future Ideas) 🚀

* **Finish Phase 7:** Add the fancy AWS databases (RDS, DynamoDB) to make the app even better.
* **Perfect the Blueprints:** Add the LBC IAM Role back into the `Project-Bedrock-Core.yaml` CloudFormation file so everything is defined in code (no manual steps!).
* **Add Monitoring:** Set up tools like Prometheus and Grafana (or AWS CloudWatch) to keep an eye on how the app is doing.
