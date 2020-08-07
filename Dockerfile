FROM confluentinc/cp-server-connect-operator:5.5.1.0

RUN   confluent-hub install --no-prompt confluentinc/kafka-connect-mqtt:1.2.4 \
   && confluent-hub install --no-prompt confluentinc/kafka-connect-aws-lambda:1.0.1