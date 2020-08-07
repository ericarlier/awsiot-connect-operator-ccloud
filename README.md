# Connect AWS IoT to Confluent Cloud

Using Confluent Operator to deploy a self-managed Kafka Connect cluster with a MQTT connector deployed subsribing to AWS IoT topic and producing to a Confluent Cloud Cluster

Operator also deploys Confluent Control Center, especially to view and monitor deployed connectors

Contact: eric.carlier@confluent.io

## STEPS:

### 1. Setup you AWS IoT core service

* Go to your AWS IoT Core Service Console
* On the left menu, choose "Onboard -> Get started"
* Select "Onboard a device / Get Started"
* Click "Get started"
* Choose whatever platform and language you like and click "Next"
* Give a name of your choice [YourThing]
* Download the connection kit
* Click "Next" and "Done" 
* Unzip the downloaded connection kit
* At the root, you will find
  * A certificate for your thing [YourThing].cert.pem
  * A private key [YourThing].private.key
  * A public key [YourThing].public.key
* Now let's generate our truststore:
  * Go to https://docs.aws.amazon.com/iot/latest/developerguide/server-authentication.html#server-authentication-certs, download the "Amazon Root CA 1" and copy the content in a file named `root-CA.crt`
  * Generate truststore with following command : `keytool -importcert -alias "amazon-root-ca-1" -file root-CA.crt -keystore truststore.jks -storetype JKS`
  * Set your truststore password [TRUSTSTORE_PWD] as requested by the previous command
* Now let's do our keystore:
  * First protect your private key : `openssl rsa -aes256 -in [YourThing].private.key -out [YourThing].private.key.encrypted.pem` and set the passphrase as requested ([KEY_PWD])
  * Let's now create a p12 version of the certificate/key pair : `openssl pkcs12 -export -in [YourThing].cert.pem -inkey [YourThing].private.key.encrypted.pem -certfile [YourThing].cert.pem -out tempkeystore.p12`, enter the passphrase you set in previous command, and set an export password
  * Finally we can create our keystore: `keytool -importkeystore -destkeystore keystore.jks -deststoretype JKS -destalias "aws-iot-cert"  -srckeystore tempkeystore.p12 -srcstoretype PKCS12 -srcalias 1`, and set your [KEYSTORE_PWD]
* At this point, the important elements for the rest of this demo is :
  * the `truststore.jks` and `keystore.jks`files you generated
  * and the different passwords you set [KEY_PWD], [KEYSTORE_PWD] and [TRUSTSTORE_PWD]
* Now we need to modify and save the policies attached to your thing:
  * Go back to the AWS IoT Core Console
  * On the left menu, select "Secure -> Policies"
  * You should see a "[YourThing]-Policy"
  * Click on it, and on next page select "Edit policy document"
  * You should here adapt the policies to whatever topic you want your connector to publish or subscribe to, and whatever filters you might use on subscription. **But the important thing is that, as of today, the MQTT Connector does not allow to set a Client ID, therefore in the Connect section, you shall have "[your-arn]:client/*" in the Resource list**

Now we are good to go on the Confluent side of the demo

### 2. Build the docker connect image containing the MQTT connector  

Indeed the default image only contains a few connectors, so this step is required to correctly install the connector jars into the image 

The example `Dockerfile` here does that for you. This one for instance installs both the MQTT connector and the AWS Lambda sink connector.
If you want to integrate other connectors, just add the corresponding confluent-hub command
Check connectors at https://confluent.io/hub


```
# cd the root directory of this project (where the Dockerfile is) 
#Build the image:
docker build -t [your_dockerhub_account]/connectors:[your_tag] .
docker push [your_dockerhub_account]/connectors:[your_tag]
```
Publish to a place / repo where your k8s cluster will be able to pull it.

### 3. Confluent Cloud Setup

If you have not already setup a Confluent Cloud organisation and cluster, please follow the steps here : https://docs.confluent.io/current/quickstart/cloud-quickstart/index.html

It is just easy !

Once you have a cluster set up:
1. Create a 'mqtt' topic (topic name used by default by the MQTT source connector to publish to. You can change the name if you want in the connector config)
1. and then generate an api key and secret either through the Confluent Cloud UI or through the ccloud CLI:
```
ccloud api-key create --resource [YOUR_CLUSTER_ID]
```
We are done here :-)
Just remember your Confluent Cloud Key and Secret as we will need them later

### 4. Deploy Connectors and Control Center on AWS EKS with Confluent Operator 

*(Pre-req: spin up a k8s cluster on EKS)*

fyi I used eksctl command line but there other ways
```
eksctl create cluster \
--name [my-eks-cluster-name] \
--version 1.17 \
--region [my-region] \
--nodegroup-name [my-node-group] \
--node-type m5.large \
--nodes 3 \
--nodes-min 2 \
--nodes-max 3 \
--ssh-access \
--ssh-public-key [my-public-key] \
--managed
```

Download and install Operator
You can get it from this page and then unzip it : https://docs.confluent.io/current/installation/operator/co-download.html

Copy and rename the template values file provided in this project
```
cp [PROJECT_ROOT]/helm/connector/connect-cluster-template.yaml [OPERATOR_INSTALL_DIR]/helm/providers/[MY_VALUES_YAML]
```
Now edit the `[MY_VALUES_YAML]` file and apply the correct value on any item in file marked with [...], based on what you generated in previous steps

We need to do 2 extra tricks to make it work:
1. The trustore and keystore files we crated previously need to be uploaded on the connectors pod to enable our connector to use it to connect to our AWS IoT MQTT broker. We will upload them as Kubernetes secrets, and for that we need to modify the file `[OPERATOR_INSTALL_DIR]/helm/confluent-operator/charts/connect/templates/apikeys.yaml`
You have an example of the changes to apply in `[PROJECT_ROOT]/helm/confluent-operator-changes/connect/apikeys.yaml`

[BASE64_AWS_IOT_KEYSTORE] = output of `cat keystore.jks | base64`
[BASE64_AWS_IOT_TRUSTSTORE] = output of `cat truststore.jks | base64`

2. A little patch to enable control center to work with the confluent cloud cluster. Changes is one line to be added in file `[OPERATOR_INSTALL_DIR]/helm/confluent-operator/charts/controlcenter/templates/controlcenter-psc.yaml` as showed in file `[PROJECT_ROOT]/helm/confluent-operator-changes/controlcenter/controlcenter-psc.yaml` (look for "CHANGE HERE" in this file)

Now we are good to go with deployments:
1. Create namespace
```
kubectl create namespace confluent
```
2. Deploy operator
```
cd [OPERATOR_INSTALL_DIR]/helm/
helm upgrade  --install \
  operator \
  ./confluent-operator \
  --values ./providers/[MY_VALUES_YAML] \ --namespace confluent \
  --set operator.enabled=true
```
3. Deploy Connect Cluster
```
helm upgrade  --install \
  connectors \
  ./confluent-operator \
  --values ./providers/[MY_VALUES_YAML] \ --namespace confluent \
  --set connect.enabled=true
```
4. Deploy Confluent Control Center
```
helm upgrade  --install \
  controlcenter \
  ./confluent-operator \
  --values ./providers/[MY_VALUES_YAML] \ --namespace confluent \
  --set controlcenter.enabled=true
```
5. Update your MQTT Connector config using file `[PROJECT_ROOT]/helm/connector/awsiot-connector-config-secrets-template.yaml` and changing values marked with [...] (You may also change things like MQTT topic if needed)
6. Deploy AWS IoT MQTT Connector config as secret
```
cd [PROJECT_ROOT]/helm/connector
kubectl apply -f awsiot-connector-config-secrets.yaml -n confluent
```
7. Install and start MQTT Connector
```
cd [PROJECT_ROOT]/helm/connector
kubectl apply -f deploy-awsiot-connector.yaml -n confluent
```
8. Now it should be up and running and you can test sending messages using the AWS IoT connection kit you got previously
9. If you want to check connectors, topics and messages using Confluent Control Center:
```
kubectl -n confluent port-forward controlcenter-0 12345:9021
```
Open localhost:12345 on your browser
username/pwd = admin/admin

### 5. Clean Up

```
cd [PROJECT_ROOT]/helm/connector
kubectl delete -f ./deploy-awsiot-connector.yaml -n confluent
helm uninstall controlcenter --namespace confluent
helm uninstall connectors --namespace confluent
helm uninstall operator --namespace confluent
```
And then clean up your EKS cluster if not needed anymore





