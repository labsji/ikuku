# seed.repl — Pre-configure the MVP site on first boot

Place this file alongside `docker-compose.yml`. On first boot, `init.sh` detects it and executes each command against the MVP site (port 8001) using bind's DSL.

## Format

Plain text. One DSL command per block. Blocks separated by blank lines. Comments start with `#` or `//`.

## Example

```
# Company
create Company with company_name: Srinivas Bakery, country: India, default_currency: INR

# Warehouses
create Warehouse with warehouse_name: Main Store, company: Srinivas Bakery
create Warehouse with warehouse_name: Kitchen, company: Srinivas Bakery

# Customers
create Customer with customer_name: Hotel Saravana, customer_group: Commercial, territory: Tamil Nadu
create Customer with customer_name: Walk-in, customer_group: Individual, territory: Tamil Nadu

# Suppliers
create Supplier with supplier_name: Chennai Flour Mills, supplier_group: Raw Material

# Items
create Item with item_name: Whole Wheat Bread, item_group: Finished Goods, stock_uom: Nos
create Item with item_name: Wheat Flour 10kg, item_group: Raw Material, stock_uom: Bag
```

## Syntax

| Element | Example |
|---------|---------|
| Create | `create Customer with customer_name: Ramesh, territory: India` |
| Create multiple | `create 5 customers in Retail group` |
| Update | `update Item where item_name: Bread set stock_uom = Kg` |
| List | `list customers where territory: Tamil Nadu` |
| Count | `count items` |
| Delete | `delete Customer where customer_name: Test` |
| Comment | `# this is ignored` or `// this too` |

Fields use `field_name: value` pairs separated by commas. Prepositions (`with`, `in`, `where`, `from`) are stripped — use whichever reads naturally.

## How it works

1. `init.sh` creates the MVP site and installs apps
2. Checks for `/workspace/seed.repl`
3. Calls `bind.api.execute_file` which parses and executes each block
4. Errors are logged but don't halt the boot

## Use case

A reseller runs the bind agent to configure a prospect's business, exports the DSL commands as `seed.repl`, and bundles it with the installer. The prospect gets a pre-configured MVP site on first boot.
