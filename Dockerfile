###############################################################################
# Build SQL Playground Image
###############################################################################

FROM trinodb/trino:405

COPY plugin/trino-mysql-405.jar /usr/lib/trino/plugin/mysql/trino-mysql-405.jar
RUN echo "io.trino=DEBUG" >> /etc/trino/log.properties