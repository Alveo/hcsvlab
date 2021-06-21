FROM ruby:2.1.4
RUN apt-get update -qq && apt-get install -y --force-yes build-essential libpq-dev nodejs
RUN mkdir -p /myapp/vendor
WORKDIR /myapp
COPY Gemfile /myapp/Gemfile
COPY Gemfile.lock /myapp/Gemfile.lock
COPY vendor/gems /myapp/vendor/gems
RUN gem install bundler -v '~>1' &\
    gem install therubyracer -v '0.12.1' &\
    gem install libv8 -v '3.16.14.7' -- --with-system-v8 &\
    bundle install
COPY . /myapp

COPY entrypoint.sh /usr/bin/
RUN chmod +x /usr/bin/entrypoint.sh
ENTRYPOINT ["entrypoint.sh"]
EXPOSE 3000

# Configure the main process to run when running the image
CMD ["rails", "server", "-b", "0.0.0.0"]