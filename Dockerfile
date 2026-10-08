FROM mysql:8.4.11

# Wings runs containers as its system user (default uid 988). Match it so
# mysqld has a passwd entry. Override with --build-arg if yours differs.
ARG CONTAINER_UID=988

USER root

# Wings drops capabilities a binary's file caps may ask for, and the kernel
# then refuses to exec it. Rewriting the binaries drops any such xattr.
RUN for f in /usr/sbin/mysqld /usr/bin/mysql /usr/bin/mysqladmin; do \
      [ -f "$f" ] && cp "$f" "$f.nocap" && chmod --reference="$f" "$f.nocap" && mv -f "$f.nocap" "$f"; \
    done; true

RUN useradd -m -u ${CONTAINER_UID} -d /home/container -s /bin/bash container

COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

ENV USER=container HOME=/home/container
USER container
WORKDIR /home/container

STOPSIGNAL SIGINT
ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
