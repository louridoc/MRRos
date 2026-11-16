from glob import glob

from setuptools import find_packages, setup

package_name = "ar_dev_bringup"

setup(
    name=package_name,
    version="0.1.0",
    packages=find_packages(exclude=["test"]),
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", glob("launch/*.launch.py")),
        ("share/" + package_name + "/config", glob("config/*")),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="Christian Lourido",
    maintainer_email="44009617+louridoc@users.noreply.github.com",
    description="Development bringup for MRRos (rosbridge, rsp, mock joints, rviz).",
    license="MIT",
    entry_points={
        "console_scripts": [
            "mock_joints = ar_dev_bringup.mock_joints:main",
        ],
    },
)
