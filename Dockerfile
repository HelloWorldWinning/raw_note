FROM php:7.4-apache

# Set PHP configuration to production
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

# Enable rewrite; set ServerName to silence the AH00558 warning at start-up.
RUN a2enmod rewrite \
 && echo 'ServerName localhost' > /etc/apache2/conf-available/servername.conf \
 && a2enconf servername

# Import App
COPY .htaccess index.php search.php list.php \
     styles.css script.js token_badge.js favicon.ico notes.htaccess \
     .Longman_Communication_3000.txt ./

# Entrypoint: notes folder permissions + optional basic auth
COPY minimalist-web-notepad-entrypoint /usr/local/bin/
ENTRYPOINT ["minimalist-web-notepad-entrypoint"]
CMD ["apache2-foreground"]
