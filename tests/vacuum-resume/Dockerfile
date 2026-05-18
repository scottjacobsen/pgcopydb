FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh

USER root
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 \
    && rm -rf /var/lib/apt/lists/*

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
