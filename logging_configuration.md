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

# Logging Configuration
The CloudStack log files grow unbounded by default.  If you don't want to manage them yourself, you can use these steps
to limit the amount of disk space they use.

## CloudStack Logs
CloudStack uses log4j XML files to hold the logging configuration.  There are separate config files for the management server and the agent.  (The agent is found on the VM host machines.)  Feel free to adjust the policy values shown below as needed.

### Management Server
Edit `/etc/cloudstack/management/log4j.xml`.  Find the `rollingPolicy` that refers to `management-server.log`, and replace it with this:

```xml
      <rollingPolicy class="org.apache.log4j.rolling.FixedWindowRollingPolicy">
        <param name="ActiveFileName" value="/var/log/cloudstack/management/management-server.log" />
        <param name="FileNamePattern" value="/var/log/cloudstack/management/management-server.log.%i.gz" />
        <param name="MinIndex" value="1" />
        <param name="MaxIndex" value="4" />
      </rollingPolicy>
      <triggeringPolicy class="org.apache.log4j.rolling.SizeBasedTriggeringPolicy">
          <param name="MaxFileSize" value="104857600" />
      </triggeringPolicy>
```

Next find the rolling policy that refers to `apilog.log`, and replace it with this:

```xml
      <rollingPolicy class="org.apache.log4j.rolling.FixedWindowRollingPolicy">
        <param name="ActiveFileName" value="/var/log/cloudstack/management/apilog.log" />
        <param name="FileNamePattern" value="/var/log/cloudstack/management/apilog.log.%i.gz" />
        <param name="MinIndex" value="1" />
        <param name="MaxIndex" value="4" />
      </rollingPolicy>
      <triggeringPolicy class="org.apache.log4j.rolling.SizeBasedTriggeringPolicy">
          <param name="MaxFileSize" value="104857600" />
      </triggeringPolicy>
```

To make the changes take effect, run `systemctl restart cloudstack-management`.

### Agent
Edit `/etc/cloudstack/agent/log4j-cloud.xml`.  Find the `rollingPolicy` that refers to `agent.log`, and replace it with this:

```xml
      <rollingPolicy class="org.apache.log4j.rolling.FixedWindowRollingPolicy">
        <param name="ActiveFileName" value="/var/log/cloudstack/agent/agent.log" />
        <param name="FileNamePattern" value="/var/log/cloudstack/agent/agent.log.%i.gz" />
        <param name="MinIndex" value="1" />
        <param name="MaxIndex" value="10" />
      </rollingPolicy>
      <triggeringPolicy class="org.apache.log4j.rolling.SizeBasedTriggeringPolicy">
          <param name="MaxFileSize" value="10485760" />
      </triggeringPolicy>
```

To make the change take effect, run `systemctl restart cloudstack-agent`.

## Tomcat Logs
CloudStack uses Apache Tomcat, and it has its own access log.  I've never seen it get very big, so you might not need to worry about it.  If you want to truncate it daily, add a cron job like this:

```bash
cat << EOF > /etc/cron.daily/truncate_cloudstack_tomcat_log
#!/bin/bash
truncate --size 0 /var/log/cloudstack/management/access.log
EOF

chmod +x /etc/cron.daily/truncate_cloudstack_tomcat_log
```