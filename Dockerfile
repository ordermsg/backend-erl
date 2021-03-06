FROM erlang:22
RUN mkdir /yamkabackend
WORKDIR /yamkabackend
COPY ./ ./
RUN rebar3 release
RUN mkdir /run/email_templates
RUN cp email/* /run/email_templates/
EXPOSE 1746/tcp 1747/udp
EXPOSE 9042/tcp

CMD _build/default/rel/yamkabackend/bin/yamkabackend foreground