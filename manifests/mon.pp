#
#   Copyright (C) 2013 Cloudwatt <libre.licensing@cloudwatt.com>
#   Copyright (C) 2013, 2014 iWeb Technologies Inc.
#   Copyright (C) 2014 Nine Internet Solutions AG
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
# Author: Loic Dachary <loic@dachary.org>
# Author: David Moreau Simard <dmsimard@iweb.com>
# Author: David Gurtner <aldavud@crimson.ch>
#
# == Define: ceph::mon
#
# Installs and configures MONs (ceph monitors)
#
# === Parameters:
#
# [*title*] The MON id.
#   Mandatory. An alphanumeric string uniquely identifying the MON.
#
# [*ensure*] Installs ( present ) or remove ( absent ) a MON
#   Optional. Defaults to present.
#   If set to absent, it will stop the MON service and remove
#   the associated data directory.
#
# [*mon_enable*] Whether to enable ceph-mon instance on boot.
#   Optional. Default is true.
#
# [*cluster*] The ceph cluster
#   Optional. Same default as ceph.
#
# [*authentication_type*] Activate or deactivate authentication
#   Optional. Default to cephx.
#   Authentication is activated if the value is 'cephx' and deactivated
#   if the value is 'none'. If the value is 'cephx', at least one of
#   key or keyring must be provided.
#
# [*key*] Authentication key for [mon.]
#   Optional. $key and $keyring are mutually exclusive.
#
# [*keyring*] Path of the [mon.] keyring file
#   Optional. $key and $keyring are mutually exclusive.
#
# [*exec_timeout*] The default exec resource timeout, in seconds
#   Optional. Defaults to $::ceph::params::exec_timeout
#

class kalimdor::mon (
  $ensure = present,
  $mon_enable = true,
  $cluster = undef,
  $authentication_type = 'cephx',
  $key = $::kalimdor::params::mon_key,
  $keyring  = undef,
  $exec_timeout = $::kalimdor::params::exec_timeout,
) {

    # set MON configs in ceph.conf
    include ::stdlib
    include kalimdor::configs::mon

    # a puppet name translates into a ceph id, the meaning is different
    $id = $::hostname

    # set cluster name
    if $cluster {
      $cluster_name = $cluster
      $cluster_option = "--cluster ${cluster_name}"
    } else {
      $cluster_name = 'ceph'
    }   

    # NOTE(aschultz): this is the service title for the mon service. It may be
    # different than the actual service name.

    $mon_service = "ceph-mon-${id}"
    # For Ubuntu Trusty system
    if $::service_provider == 'upstart' {
      $init = 'upstart'
      Service {
        name     => "ceph-mon-${id}",
        provider => $::ceph::params::service_provider,
        start    => "start ceph-mon id=${id}",
        stop     => "stop ceph-mon id=${id}",
        status   => "status ceph-mon id=${id}",
        enable   => $mon_enable,
      }
    # Everything else that is supported by puppet-ceph should run systemd.
    } else {
      $init = 'systemd'
      Service {
        name   => "ceph-mon@${id}",
        enable => $mon_enable,
      }
    }

    if $ensure == present {

      $ceph_mkfs = "ceph-mon-mkfs-${id}"

      if $authentication_type == 'cephx' {
        if ! $key and ! $keyring {
          fail("authentication_type ${authentication_type} requires either key or keyring to be set but both are undef")
        }
        if $key and $keyring {
          fail("key (set to ${key}) and keyring (set to ${keyring}) are mutually exclusive")
        }
        if $key {
          $keyring_path = "/tmp/ceph-mon-keyring-${id}"

          Ceph_config<||> ->
          exec { "create-keyring-${id}":
            command => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
cat > ${keyring_path} << EOF
[mon.]
    key = ${key}
    caps mon = \"allow *\"
EOF

chmod 0444 ${keyring_path}
",
            unless  => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
mon_data=\$(ceph-mon ${cluster_option} --id ${id} --show-config-value mon_data) || exit 1
# if ceph-mon fails then the mon is probably not configured yet
test -e \$mon_data/done
",
          }

          Exec["create-keyring-${id}"] -> Exec[$ceph_mkfs]

        } else {
          $keyring_path = $keyring
        }

      } else {
        $keyring_path = '/dev/null'
      }

      Ceph_config<||> ->
      # prevent automatic creation of the client.admin key by ceph-create-keys
      exec { "ceph-mon-${cluster_name}.client.admin.keyring-${id}":
        command => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
touch /etc/ceph/${cluster_name}.client.admin.keyring",
        unless  => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
test -e /etc/ceph/${cluster_name}.client.admin.keyring",
      }
      ->
      exec { $ceph_mkfs:
        command   => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
mon_data=\$(ceph-mon ${cluster_option} --id ${id} --show-config-value mon_data)
if [ ! -d \$mon_data ] ; then
    mkdir -p \$mon_data
    if getent passwd ceph >/dev/null 2>&1; then
        chown -h ceph:ceph \$mon_data
        if ceph-mon ${cluster_option} \
              --setuser ceph --setgroup ceph \
              --mkfs \
              --id ${id} \
              --keyring ${keyring_path} ; then
            touch \$mon_data/done \$mon_data/${init} \$mon_data/keyring
            chown -h ceph:ceph \$mon_data/done \$mon_data/${init} \$mon_data/keyring
        else
            rm -fr \$mon_data
        fi
    else
        if ceph-mon ${cluster_option} \
              --mkfs \
              --id ${id} \
              --keyring ${keyring_path} ; then
            touch \$mon_data/done \$mon_data/${init} \$mon_data/keyring
        else
            rm -fr \$mon_data
        fi
    fi
fi
",
        unless    => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
mon_data=\$(ceph-mon ${cluster_option} --id ${id} --show-config-value mon_data)
test -d  \$mon_data
",
        logoutput => true,
        timeout   => $exec_timeout,
      }->
      service { $mon_service:
        ensure => running,
      }

      # if the service is running before we setup the configs, notify service
      Ceph_config<||> ~>
        Service[$mon_service]

      if $authentication_type == 'cephx' {
        if $key {
          Exec[$ceph_mkfs] -> Exec["rm-keyring-${id}"]

          exec { "rm-keyring-${id}":
            command => "/bin/rm ${keyring_path}",
            unless  => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
test ! -e ${keyring_path}
",
          }
        }

        Service[$mon_service] -> Kalimdor::Key['client.admin']
        kalimdor::key { 'client.admin':
          secret  => $kalimdor::params::admin_key,
          cluster => $cluster,
          keyring_path =>  "/etc/ceph/${cluster}.client.admin.keyring",
          cap_mon => 'allow *',
          cap_osd => 'allow *',
          cap_mds => 'allow *',
          user    => 'ceph',
          group   => 'ceph',
          inject         => true,
          inject_as_id   => 'mon.',
          inject_keyring => "/var/lib/ceph/mon/${cluster}-${id}/keyring",
        } ->
        class {'kalimdor::bootstrap_keys':
          cluster => $cluster,
        }
      }
    } elsif $ensure == absent {
      service { $mon_service:
        ensure => stopped
      }
      ->
      exec { "remove-mon-${id}":
        command   => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
mon_data=\$(ceph-mon ${cluster_option} --id ${id} --show-config-value mon_data)
rm -fr \$mon_data
",
        unless    => "/bin/true # comment to satisfy puppet syntax requirements
set -ex
which ceph-mon || exit 0 # if ceph-mon is not available we already uninstalled ceph and there is nothing to do
mon_data=\$(ceph-mon ${cluster_option} --id ${id} --show-config-value mon_data)
test ! -d \$mon_data
",
        logoutput => true,
        timeout   => $exec_timeout,
      } -> Package<| tag == 'ceph' |>
    } else {
      fail('Ensure on MON must be either present or absent')
    }
  }
