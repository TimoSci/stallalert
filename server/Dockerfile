# server/Dockerfile
FROM hexpm/elixir:1.19.5-erlang-28.5.0.3-alpine-3.21.7 AS build
WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile
COPY config config
COPY lib lib
RUN mix release

FROM alpine:3.21.7
RUN apk add --no-cache libstdc++ openssl ncurses-libs
WORKDIR /app
COPY --from=build /app/_build/prod/rel/stallalert ./
ENV PORT=4000
EXPOSE 4000
CMD ["bin/stallalert", "start"]
