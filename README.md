# Wireguard
Modified scripts based on the "official" recommendation on setting up [WireGuard]([url](https://upvpn.app/articles/post/wireguard-vpn-on-hetzner))

## First time setup on the server
1. copy the contents of `setup-wireguard.sh` to the server
2. `chmod +x setup-wireguard.sh`
3. `./setup-wireguard.sh`

The script will bootstrap everything necessary. After it's finished, it will produce the contents of the client's config file. 

## Adding new clients to the server
1. copy the contents of `add-client.sh` to the server
2. `chmod +x add-client.sh`
3. `./add-client.sh`

The script will count the number of existing client peers, and produce the configuration for the new client. 
