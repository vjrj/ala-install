## {{cookiecutter.LA_project_name}} Ansible Inventories

These are some generated inventories to use to set up some machines on EC2 or other cloud provider with LA software.


### Initial Setup

To use this, add the following into your `/etc/hosts` (of your working machine, and new service machine/s) and/or in your {{cookiecutter.LA_domain}} `DNS`. So these hostname should be accessible from your local working machine but also remotely between each machine/s so the hostname should resolve correctly.

```
12.12.12.12  {{cookiecutter.LA_pkg_name}} {{cookiecutter.LA_domain}}
{% if cookiecutter.LA_collectory_uses_subdomain == 'yes' %}12.12.12.13  {{cookiecutter.LA_collectory_hostname}}{% endif %}
{% if cookiecutter.LA_ala_hub_uses_subdomain == 'yes' %}12.12.12.14  {{cookiecutter.LA_ala_hub_hostname}}{% endif %}
{% if cookiecutter.LA_biocache_service_uses_subdomain == 'yes' %}12.12.12.15  {{cookiecutter.LA_biocache_service_hostname}}{% endif %}
{% if cookiecutter.LA_ala_bie_uses_subdomain == 'yes' %}12.12.12.16  {{cookiecutter.LA_ala_bie_hostname}}{% endif %}
{% if cookiecutter.LA_bie_index_uses_subdomain == 'yes' %}12.12.12.17  {{cookiecutter.LA_bie_index_hostname}}{% endif %}
{% if cookiecutter.LA_lists_uses_subdomain == 'yes' %}12.12.12.18  {{cookiecutter.LA_lists_hostname}}{% endif %}
{% if cookiecutter.LA_images_uses_subdomain == 'yes' %}12.12.12.19  {{cookiecutter.LA_images_hostname}}{% endif %}
{% if cookiecutter.LA_logger_uses_subdomain == 'yes' %}12.12.12.20  {{cookiecutter.LA_logger_hostname}}{% endif %}
{% if cookiecutter.LA_use_CAS == 'yes' %}12.12.12.21  {{cookiecutter.LA_cas_hostname}}{% endif %}
```

You'll need to replace `12.12.12.12` etc with the IP address of some new Ubuntu 16 instance in your provider.

These machines should have an user `ubuntu` with `sudo` permissions.

You should generate and use some ssh key and copy `~/.ssh/MyKey.pub` in thouse machines under `~ubuntu/.ssh/authorized_keys` (via `ssh-copy-id` for avoid issues).

You can test your initial setup with some `ssh` command like:
```
ssh -i ~/.ssh/MyKey.pem ubuntu@12.12.12.12 sudo ls /root
```
that should work.

### Run ansible

With access to this machine/s you can run ansible:

```
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -s -i inventories/{{cookiecutter.LA_pkg_name}}.yml ../ansible/ala-demo.yml

```

### TODO

- [x] Add basic services (`collectory`, `ala-hub`, etc).
- [x] Add domain/context and service subdomains support
- [x] Add `http`/`https` urls support (this does **not** include `ssl` certificates management)
- [ ] Add `regions` service
- [ ] Add `species-list` service
- [ ] Add `spatial` service
- [ ] Add `CAS` 5 service
- [ ] Disable caches when using the same host for collectory & biocache
