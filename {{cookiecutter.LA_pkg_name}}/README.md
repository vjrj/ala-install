## {{cookiecutter.LA_project_name}} Ansible Inventories

These are some generated inventories to use to set up some machines on EC2 or other cloud provider with LA software.


### Initial Setup

To use this add the following into your /etc/hosts file:

```
 12.12.12.12	{{cookiecutter.LA_pkg_name}}	{{cookiecutter.LA_domain}}
```

You'll need to replace "12.12.12.12" with the IP address of some new Ubuntu 16 instance in your provider.

These machines should have an user 'ubuntu' with `sudo` permissions and with some ssh key `~/.ssh/MyKey.pub` in `~ubuntu/.ssh/authorized_keys`.

### Run ansible

```
ansible-playbook --private-key ~/.ssh/MyKey.pem -u ubuntu -s -i inventories/{{cookiecutter.LA_pkg_name}}.yml ../ansible/ala-demo.yml
# TODO add spatial, etc
```
