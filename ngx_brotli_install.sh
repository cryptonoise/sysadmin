#!/bin/bash

# Specify the desired version of NGINX
ngver=1.24.0

moddir=/usr/lib/nginx/modules

# Install necessary packages for NGINX compilation and installation
sudo apt-get install -y build-essential git libpcre3 libpcre3-dev zlib1g zlib1g-dev openssl libssl-dev cmake

# Check if NGINX is installed
nginx_installed=$(command -v nginx)
if [ -z "$nginx_installed" ]; then
    # If NGINX is not installed, install it
    sudo apt-get install -y nginx
fi

# Check if Brotli is downloaded
brotli_installed=$(nginx -V 2>&1 | grep -oP -- '--add-dynamic-module=../ngx_brotli')
if [ -z "$brotli_installed" ]; then
    # If Brotli is not downloaded, clone the repository
    git clone --recurse-submodules -j8 https://github.com/google/ngx_brotli
    cd ngx_brotli
    git submodule update --init
    cd ..
fi

# Download and unpack NGINX
nginx_url="https://nginx.org/download/nginx-${ngver}.tar.gz"
nginx_filename="nginx-${ngver}.tar.gz"
wget $nginx_url -O $nginx_filename && tar zxf $nginx_filename && rm $nginx_filename

# Compile NGINX with the Brotli module
cd nginx-${ngver}
./configure --with-compat --add-dynamic-module=../ngx_brotli
make && sudo make install

# Check if the build was successful
if [ $? -eq 0 ]; then
    # Find the path to the NGINX configuration file
    nginx_conf_path=$(nginx -V 2>&1 | grep -oP -- '--conf-path=\K[^ ]+')

    # Add load_module directives to the beginning of the configuration file
    sudo sed -i '1i load_module modules/ngx_http_brotli_filter_module.so;' $nginx_conf_path
    sudo sed -i '2i load_module modules/ngx_http_brotli_static_module.so;' $nginx_conf_path
    sudo nginx -t
    
    # Restart NGINX
    sudo systemctl restart nginx

    # Display NGINX status
    sudo systemctl status nginx
    
    # Add ufw rule
    sudo ufw allow 'Nginx Full'
else
    echo "Failed to build NGINX with the Brotli module. Check the build logs for errors."
fi
