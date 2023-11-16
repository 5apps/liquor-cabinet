# FROM ruby:3.1.4
FROM ruby:2.7.8

WORKDIR /liquorcabinet
ENV RACK_ENV=production

COPY Gemfile Gemfile.lock /liquorcabinet/
RUN bundle install
COPY . /liquorcabinet
COPY ./config.yml.erb.example /liquorcabinet/config.yml.erb

EXPOSE 4567

CMD ["bundle", "exec", "rainbows", "--listen", "0.0.0.0:4567"]
