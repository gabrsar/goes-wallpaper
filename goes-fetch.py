#!/usr/bin/env python3
"""
GOES Satellite Image Fetcher

This script downloads the most recent GOES satellite imagery from NOAA's website
based on user configuration and saves it to a local directory.
"""

import os
import sys
import time
import re
import subprocess
import logging
from datetime import datetime
from pathlib import Path
import requests


class GOESImageFetcher:
    """
    A class to fetch and manage GOES satellite imagery.
    
    This class handles downloading satellite images from NOAA's website,
    saving them locally, and managing the image collection.
    """
    
    def __init__(self):
        """Initialize the GOESImageFetcher with default configuration."""
        # Set up logging
        logging.basicConfig(
            level=logging.INFO,
            format='[DEBUG_LOG] %(message)s',
            stream=sys.stderr
        )
        self.logger = logging.getLogger(__name__)
        
        # Get script directory
        self.script_dir = Path(__file__).parent.absolute()
        self.logger.info(f"SCRIPT_DIR: {self.script_dir}")
        
        # Set up save directory
        self.save_dir = self.script_dir / ".goes-wallpaper-data"
        self.logger.info(f"SAVE_DIR: {self.save_dir}")
        
        # Ensure save directory exists
        self.save_dir.mkdir(exist_ok=True)
        self.logger.info("Created SAVE_DIR if it didn't exist")
        
        # Load configuration
        self.load_configuration()
    
    def load_configuration(self):
        """Load user configuration from config files."""
        home_dir = Path.home()
        
        # Check if user wants to keep all images
        keep_images_file = home_dir / ".config" / "goes-keep-images"
        if keep_images_file.exists():
            self.keep_files = keep_images_file.read_text().strip().lower() == "true"
            self.logger.info(f"KEEP_FILES set from config: {self.keep_files}")
        else:
            self.keep_files = False
            self.logger.info(f"KEEP_FILES defaulting to: {self.keep_files}")
        
        # Get satellite configuration
        sat_file = home_dir / ".config" / "goes-sat"
        if sat_file.exists():
            self.sat = sat_file.read_text().strip()
            self.logger.info(f"SAT from config: {self.sat}")
        else:
            self.logger.error(f"ERROR: {sat_file} file not found")
            sys.exit(1)
        
        # Get sector configuration
        sector_file = home_dir / ".config" / "goes-sector"
        if sector_file.exists():
            self.sector = sector_file.read_text().strip()
            self.logger.info(f"SECTOR from config: {self.sector}")
        else:
            self.logger.error(f"ERROR: {sector_file} file not found")
            sys.exit(1)
        
        # Prepare URL parameters and base filename
        if self.sat.startswith('G'):
            self.sat_url_param = self.sat
            self.base = f"{self.sat}_{self.sector}_"
            self.logger.info(f"SAT already has G prefix: {self.sat_url_param}")
        else:
            self.sat_url_param = f"G{self.sat}"
            self.base = f"G{self.sat}_{self.sector}_"
            self.logger.info(f"Added G prefix to SAT: {self.sat_url_param}")
        
        self.logger.info(f"BASE filename prefix: {self.base}")
        
        # Extract satellite number
        match = re.search(r'(\d+)', self.sat_url_param)
        if match:
            self.sat_num = match.group(1)
            self.logger.info(f"Extracted satellite number: {self.sat_num}")
        else:
            self.logger.error(f"Could not extract satellite number from {self.sat_url_param}")
            sys.exit(1)
    
    def fetch_sector_page(self):
        """Fetch the sector page from NOAA's website."""
        page_file = self.save_dir / "sector_page.html"
        self.logger.info(f"PAGE_FILE: {page_file}")
        
        url = f"https://www.star.nesdis.noaa.gov/GOES/sector.php?sat={self.sat_url_param}&sector={self.sector}"
        self.logger.info(f"Fetching sector page from NOAA website...")
        
        try:
            response = requests.get(url)
            response.raise_for_status()
            
            with open(page_file, 'w') as f:
                f.write(response.text)
            
            self.logger.info("Successfully downloaded sector page")
            self.logger.info(f"Page size: {len(response.text)} bytes")
            
            return page_file
        except requests.exceptions.RequestException as e:
            self.logger.error(f"ERROR: Failed to download sector page: {e}")
            sys.exit(1)
    
    def find_latest_image_url(self, page_file):
        """Find the URL of the latest satellite image."""
        self.logger.info("Looking for image URLs in the page...")
        
        try:
            with open(page_file, 'r') as f:
                content = f.read()
            
            # Look for URLs that match the format
            pattern = f"href='[^']+GOES{self.sat_num}/ABI/SECTOR/{self.sector}/[^']+\\.jpg'"
            matches = re.findall(pattern, content)
            
            # Filter out "latest" URLs and extract the actual URL
            urls = [match.replace("href='", "").replace("'", "") for match in matches if "latest" not in match]
            
            if not urls:
                self.logger.error(f"ERROR: No image found for {self.sat_url_param} sector {self.sector}")
                print(f"No image found for {self.sat_url_param} sector {self.sector}.")
                sys.exit(1)
            
            # Sort URLs in descending order and get the first one
            highest_url = sorted(urls, reverse=True)[0]
            self.logger.info(f"Found highest URL: {highest_url}")
            
            return highest_url
        except Exception as e:
            self.logger.error(f"ERROR: Failed to find latest image URL: {e}")
            sys.exit(1)
    
    def download_image(self, url):
        """Download the satellite image from the given URL."""
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
        file_name = self.save_dir / f"{self.base}{timestamp}.jpg"
        self.logger.info(f"Saving image to: {file_name}")
        
        self.logger.info("Downloading image...")
        try:
            response = requests.get(url)
            response.raise_for_status()
            
            with open(file_name, 'wb') as f:
                f.write(response.content)
            
            self.logger.info("Successfully downloaded image")
            self.logger.info(f"Image size: {len(response.content)} bytes")
            
            # Check if the file is a valid image
            if os.path.getsize(file_name) > 0:
                self.logger.info("Image file is not empty")
            else:
                self.logger.warning("WARNING: Downloaded image file is empty")
            
            # Save the URL to a file for reference
            with open(self.save_dir / "FD-last_url.txt", 'w') as f:
                f.write(url)
            self.logger.info(f"Saved URL to: {self.save_dir}/FD-last_url.txt")
            
            return file_name
        except requests.exceptions.RequestException as e:
            self.logger.error(f"ERROR: Failed to download image: {e}")
            sys.exit(1)
    
    def cleanup_old_images(self):
        """Clean up old images, keeping only the 2 most recent ones."""
        if not self.keep_files:
            self.logger.info("Not keeping all files, cleaning up old ones")
            
            # Get all image files for this satellite and sector
            pattern = f"{self.base}*.jpg"
            all_files = sorted(
                self.save_dir.glob(pattern),
                key=os.path.getmtime,
                reverse=True
            )
            
            self.logger.info(f"Found files: {len(all_files)}")
            
            # If there are more than 2 files, delete the older ones
            if len(all_files) > 2:
                self.logger.info("More than 2 files found, deleting older ones")
                for file in all_files[2:]:
                    os.remove(file)
                self.logger.info("Cleaned up old images, keeping only the 2 most recent")
            else:
                self.logger.info("2 or fewer files found, no cleanup needed")
        else:
            self.logger.info("Keeping all files, no cleanup needed")
    
    def run(self):
        """Run the full image fetching process."""
        try:
            # Fetch the sector page
            page_file = self.fetch_sector_page()
            
            # Find the latest image URL
            url = self.find_latest_image_url(page_file)
            
            # Download the image
            file_name = self.download_image(url)
            
            # Clean up old images
            self.cleanup_old_images()
            
            # Return the path to the downloaded image
            self.logger.info(f"Returning file name: {file_name}")
            print(file_name)
            return str(file_name)
        except Exception as e:
            self.logger.error(f"Unexpected error: {e}")
            sys.exit(1)


if __name__ == "__main__":
    fetcher = GOESImageFetcher()
    fetcher.run()