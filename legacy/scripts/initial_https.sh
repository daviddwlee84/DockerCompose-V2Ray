#!/bin/bash

your_domain="your_domain"
your_email_address="your_email_address"

sed -i "s/your_domain/$your_domain/" data/nginx/conf.d/v2ray.conf
sed -i "s/your_domain/$your_domain/" init-letsencrypt.sh
sed -i "s/your_email_address/$your_email_address/" init-letsencrypt.sh

./init-letsencrypt.sh
