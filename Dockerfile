###############################################################################
# Build SQL Playground Image
###############################################################################

FROM trinodb/trino:408

COPY plugin/trino-mysql-408.jar /usr/lib/trino/plugin/mysql/trino-mysql-408.jar
RUN echo "io.trino=DEBUG" >> /etc/trino/log.properties