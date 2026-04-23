FROM eclipse-temurin:17-jre-alpine

RUN apk add --no-cache curl bash python3 py3-pip \
    && pip3 install awscli --break-system-packages 2>/dev/null || pip3 install awscli

ENV JMETER_VERSION=5.6.3
ENV JMETER_HOME=/opt/apache-jmeter-${JMETER_VERSION}
ENV PATH="${JMETER_HOME}/bin:${PATH}"

RUN curl -sL \
    https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz \
    -o /tmp/jmeter.tgz \
    && tar -xzf /tmp/jmeter.tgz -C /opt \
    && rm /tmp/jmeter.tgz

WORKDIR /jmeter
COPY jmeter/wager-purchase-test.jmx ./test-plan.jmx
COPY jmeter-image/run-tests.sh ./run-tests.sh
RUN chmod +x ./run-tests.sh

ENTRYPOINT ["./run-tests.sh"]
