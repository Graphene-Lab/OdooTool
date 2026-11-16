#!/usr/bin/env python3
"""Create an API key for OdooTool in the odoo_test database using Odoo 20 API."""
import sys, os
os.chdir('/opt/odoo20')
sys.path.insert(0, '/opt/odoo20')

import odoo
from odoo.modules.registry import Registry
from odoo.tools import config

config.parse_config(['-d', 'odoo_test', '--db_user=odoo', '--db_password=REMOVED', '--db_host=localhost', '--no-http'])
registry = Registry.new('odoo_test')

with registry.cursor() as cr:
    env = odoo.api.Environment(cr, 1, {})
    admin = env['res.users'].search([('login', '=', 'admin')])
    if not admin:
        print("ERROR: admin user not found")
        sys.exit(1)
    
    key = env['res.users.apikeys'].create({
        'name': 'AgentBridge',
        'user_id': admin.id,
        'key_id': 'agentbridge',
        'secret': 'odoo_agent_key_2026',
    })
    cr.commit()
    print(f"API_KEY=agentbridge:odoo_agent_key_2026")
    print(f"USER_ID={admin.id}")
    print("SUCCESS")
