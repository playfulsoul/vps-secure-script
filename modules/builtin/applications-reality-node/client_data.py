"""Pure client-link formatting shared by protected export and interactive viewing."""
from urllib.parse import urlencode

from node_config import validate_credentials
from preflight import validate_endpoint
from target_check import validate_target


def share_uri(settings):
    validate_endpoint(settings['public_address'])
    validate_target(settings['target_host'], settings['target_port'], settings['server_name'], settings['node_port'])
    public = settings['public_key']
    # Both X25519 keys use the same canonical representation. Validate the public
    # key here; client formatting never needs or retrieves the server private key.
    validate_credentials(settings['client_id'], public, settings['short_id'])
    query = urlencode({'encryption': 'none', 'security': 'reality', 'sni': settings['server_name'],
                       'fp': 'chrome', 'pbk': public, 'sid': settings['short_id'],
                       'type': 'tcp', 'flow': 'xtls-rprx-vision'})
    return ('vless://' + settings['client_id'] + '@' + settings['public_address'] + ':'
            + str(settings['node_port']) + '?' + query + '#VPS-Secure')
