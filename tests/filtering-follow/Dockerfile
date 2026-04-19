FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./assert.sh assert.sh
COPY ./schema.sql schema.sql
COPY ./dml.sql dml.sql
COPY ./exclude.ini exclude.ini

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
