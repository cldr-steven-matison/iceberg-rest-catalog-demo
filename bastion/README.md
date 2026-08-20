# bastion/ — reach private-subnet CDP services from the Mac

The `semi-private` env keeps CDW/Trino, Hue, and the DataLake master on private subnets
(`10.10.0.0/16`); their public DNS resolves to private IPs, unreachable from outside the VPC. A
small EC2 **bastion inside the VPC** + an SSH **SOCKS proxy** gives the Mac browser a path to all of
them at their real hostnames (TLS/SNI + Knox redirects intact).

Chosen over AWS Client VPN, which fails here: the private NLB has no return route to the VPN client
CIDR, and Client VPN can't be a route-table target. A bastion's `10.10.x` source IP is in-VPC, so
the return path just works.

## Use

```bash
./bastion-up.sh                 # create/start the bastion (idempotent), prints public IP
./bastion-connect.sh <pub-ip>   # ssh -D 1080 SOCKS proxy; leave running
# Browser -> SOCKS5 127.0.0.1:1080, remote DNS ON:
#   Firefox: about:config network.proxy.socks_remote_dns = true
#   FoxyProxy: SOCKS5 127.0.0.1:1080, "send DNS through proxy" on
# Then open:
#   https://srm-trino-vw.dw-srm-iceberg-cdp-env.a465-9q4k.cloudera.site/ui/
#   https://hue-srm-trino-vw.dw-srm-iceberg-cdp-env.a465-9q4k.cloudera.site/
./bastion-up.sh --stop          # stop compute billing when idle
```

## Notes

- **Tag-keyed, not ID-keyed** — scripts resolve the VPC/subnet by `Name` tag, so they survive the
  weekly rebuild's new resource IDs. Re-run `bastion-up.sh` after a reaper cycle if the instance
  was taken.
- **SSH key** — reuses the env key pair `srm-iceberg-keypair`; private key lives at
  `../../cdp-tf-quickstarts/aws/srm-iceberg-ssh-key.pem` (gitignored, not committed).
- **SG** — `srm-iceberg-bastion-sg` opens tcp/22 to the current Mac public IP `/32` only;
  `bastion-up.sh` refreshes it each run.
- **Cost** — `t3.small` ≈ $0.02/hr; `--stop` when idle.
- `vpn-teardown.sh` — deletes the abandoned Client VPN endpoint + its ACM certs.

Full write-up + live IDs: `DesktopShare/cloudera-iceberg-rest-catalog-aws-plan.md` §External / VPC access.
