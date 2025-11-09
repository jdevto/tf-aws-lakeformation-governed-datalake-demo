#!/usr/bin/env python3
"""
Generate sample Parquet data for Lake Formation demo.

This script creates a Parquet file with sales data including:
- Multiple regions (APAC, EMEA, AMER)
- PII columns (customer_email, ssn)
- Sales data for testing row-level security and column masking
"""

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from pathlib import Path
import sys

def generate_sample_data():
    """Generate sample sales data with PII."""

    # Sample data with multiple regions and PII
    data = {
        'customer_id': [f'CUST{i:04d}' for i in range(1, 21)],
        'customer_name': [
            'Alice Johnson', 'Bob Smith', 'Charlie Brown', 'Diana Prince', 'Eve Wilson',
            'Frank Miller', 'Grace Lee', 'Henry Davis', 'Ivy Chen', 'Jack Taylor',
            'Karen White', 'Liam O\'Brien', 'Mia Garcia', 'Noah Martinez', 'Olivia Anderson',
            'Paul Thompson', 'Quinn Jackson', 'Rachel Green', 'Sam Wilson', 'Tina Brown'
        ],
        'customer_email': [
            'alice.j@example.com', 'bob.smith@example.com', 'charlie.b@example.com',
            'diana.p@example.com', 'eve.w@example.com', 'frank.m@example.com',
            'grace.lee@example.com', 'henry.d@example.com', 'ivy.chen@example.com',
            'jack.t@example.com', 'karen.w@example.com', 'liam.ob@example.com',
            'mia.g@example.com', 'noah.m@example.com', 'olivia.a@example.com',
            'paul.t@example.com', 'quinn.j@example.com', 'rachel.g@example.com',
            'sam.w@example.com', 'tina.b@example.com'
        ],
        'ssn': [
            '123-45-6789', '234-56-7890', '345-67-8901', '456-78-9012', '567-89-0123',
            '678-90-1234', '789-01-2345', '890-12-3456', '901-23-4567', '012-34-5678',
            '111-22-3333', '222-33-4444', '333-44-5555', '444-55-6666', '555-66-7777',
            '666-77-8888', '777-88-9999', '888-99-0000', '999-00-1111', '000-11-2222'
        ],
        'sales_region': [
            'APAC', 'APAC', 'APAC', 'APAC', 'APAC',  # 5 APAC records
            'EMEA', 'EMEA', 'EMEA', 'EMEA', 'EMEA',  # 5 EMEA records
            'AMER', 'AMER', 'AMER', 'AMER', 'AMER',  # 5 AMER records
            'APAC', 'APAC', 'EMEA', 'AMER', 'APAC'   # 5 more mixed
        ],
        'sales_amount': [
            1250.50, 2300.75, 1890.25, 3200.00, 1450.30,
            2100.00, 1750.50, 2900.25, 1650.75, 2400.00,
            1950.50, 2800.25, 1550.75, 3100.00, 2200.50,
            1850.25, 2600.75, 1400.00, 2700.50, 1900.25
        ],
        'sale_date': [
            '2024-01-15', '2024-01-16', '2024-01-17', '2024-01-18', '2024-01-19',
            '2024-02-10', '2024-02-11', '2024-02-12', '2024-02-13', '2024-02-14',
            '2024-03-05', '2024-03-06', '2024-03-07', '2024-03-08', '2024-03-09',
            '2024-04-20', '2024-04-21', '2024-04-22', '2024-04-23', '2024-04-24'
        ]
    }

    df = pd.DataFrame(data)

    # Convert to PyArrow table
    table = pa.Table.from_pandas(df)

    # Get output path
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    data_dir = project_root / 'data'
    data_dir.mkdir(exist_ok=True)

    output_file = data_dir / 'sales_sample.parquet'

    # Write Parquet file
    pq.write_table(table, output_file, compression='snappy')

    print(f"Sample data generated successfully!")
    print(f"File: {output_file}")
    print(f"Records: {len(df)}")
    print(f"\nData summary:")
    print(f"  APAC records: {len(df[df['sales_region'] == 'APAC'])}")
    print(f"  EMEA records: {len(df[df['sales_region'] == 'EMEA'])}")
    print(f"  AMER records: {len(df[df['sales_region'] == 'AMER'])}")

    return output_file

if __name__ == '__main__':
    try:
        generate_sample_data()
    except ImportError as e:
        print("Error: Required Python packages not installed.")
        print("Please install: pip install pandas pyarrow")
        sys.exit(1)
    except Exception as e:
        print(f"Error generating sample data: {e}")
        sys.exit(1)
