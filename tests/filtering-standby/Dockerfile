FROM pagila

COPY --from=pgcopydb /usr/local/bin/pgcopydb /usr/local/bin

WORKDIR /usr/src/pgcopydb
COPY copydb.sh copydb.sh
COPY exclude.ini exclude.ini

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
