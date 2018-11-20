Running Alveo under Docker
==

These notes document the process of getting Alveo/hcsvlab to run
in a Docker environment. 

Dockerfile
--

The Dockerfile describes the docker image required to run the
Rails application, it is derived from the standard
ruby:2.1.4 docker image and just installs the required
packages for hcsvlab.  It copies the current code into /myapp
but when we run it in development mode we'll override that
with a local mount.

docker-compose.yml
--

This file describes the combination of services that are
implemented by different docker images.  Basically each 
service like the database and activemq comes from a 
different docker image.  Each section under `services` in the yml file 
describes a different image and sets up some configuration.

In most cases a local directory is mapped to where data is to be 
stored persistently by the application.  These all map to directories
inside the local `tmp` directory.   Each time we run the containers they
will see whatever is already there so we can get persistent storage.

`web` is the rails application which will run the docker image
defined by the Dockerfile in the current directory (build: .). 
The `command` line defines the command that will be run when the
image starts.  We map the current directory onto the internal path `/myapp`
so that our local code is being run (we can edit on the fly).  We expose
port 3000 to localhost and we define dependencies on the other 
services. The dependent servers will be started before this one.

`db` defines the postgres database.  The local directory `tmp/db` is mapped
to the internal directory that postgres uses to store databases. 

`sesame` uses a relatively new sesame image, data is stored in `tmp/sesame` 
and the service is exposed on port 8080

`activemq` again uses a recent version, puts data in `tmp/activemq` and
exposes port 8161

`solr` uses version 5, old but more recent than we use in production, stores
data in `tmp/solr` and exposes port 8983

Running
--

To start the web application we run:
```
docker-compose up -d
```

the `-d` flag puts everything into the background.  To see logs use:

```bash
docker-compose logs -f
```

If it works you should be able to connect to http://localhost:3000/ to see the Alveo app.


