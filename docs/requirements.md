This document describes requirements for a cloud setup dedicated to hosting web apps.

* the setup will include:
 * one cloud vm to run multiple docker apps, and caddy as web server for the apps
  * in the future it should be possible to have multiple cloud vms running the docker apps under one load balancer
  * for start all web app domains will point to the single vm ip
 * one managament vm to host all tooling and observability stack
* the whole setup:
 * is a github repo
 * should use github actions to deploy all neccary tooling
* all cloud vms should be defined in a config in this repo
 * the ssh keys to the vms should be stored as github secrets
* all web apps:
 * come as docker container
 * are hosted on github
 * shpuld use github actions to deploy updates on push to main branch
 * can include storage folders (for example postgresql db paths), those should be defineable via github secrets)
* all apps, tools, caddy should produce logs in unified format
* all logs should be collected on the managament vm
* the managament vm should run am observability stack that allows to
 * collect, analyze and investigate logs
 * create dashboards for metrics
 * create alerts
* the managament vm should expose the obesrvability stack so it's accesible over the internet on a predefined domain name
* the setup should also consider security aspects:
 * how to monitor the source code of web apps to guard agains new security threats
 * how to audit the setup of the vms and install security updates
 * how to monitor the logs aginst threats and attacks
 * in the future the web apps will use a waf from cloudflare
