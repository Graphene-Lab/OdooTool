#!/bin/bash
K="REMOVED-API-KEY"
H1="Authorization: Bearer $K"; H2="Content-Type: application/json"; H3="X-Odoo-Database: odoo_agent"
echo "=== fleet.vehicle ==="; curl -s -X POST "http://localhost:8069/json/2/fleet.vehicle/search_read" -H "$H1" -H "$H2" -H "$H3" -d '{"domain":[],"fields":["name","license_plate","driver_id"],"limit":10}'
echo; echo "=== hr.expense ==="; curl -s -X POST "http://localhost:8069/json/2/hr.expense/search_read" -H "$H1" -H "$H2" -H "$H3" -d '{"domain":[],"fields":["name","state","total_amount"],"limit":10}'
echo; echo "=== hr.applicant ==="; curl -s -X POST "http://localhost:8069/json/2/hr.applicant/search_read" -H "$H1" -H "$H2" -H "$H3" -d '{"domain":[],"fields":["partner_name","stage_id"],"limit":10}'
echo; echo "=== calendar.attendee ==="; curl -s -X POST "http://localhost:8069/json/2/calendar.attendee/search_read" -H "$H1" -H "$H2" -H "$H3" -d '{"domain":[],"fields":["name","state"],"limit":10}'
