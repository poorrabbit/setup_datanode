# This script will get a list of roleless hosts from the CDH manager and 
# Run a parcel deployment and activation
# Install Datanode, NodeManager roles. (This assumes that the service is already setup and that we're adding new hosts.)
# Start the service

#This script has very little in the way of error or edge case detection.
#The only case it takes into account is the case that no roleless hosts are found.

# First we'll run parcel deployment and activation
# Set the URL based for the API, the CDH version number and the cluster name
BASE=http://localhost:7180/api/v10
CDH=5.10.0-1.cdh5.10.0.p0.41
CLUSTER="testcluster"

#this little bit borrowed from https://gist.github.com/azurecube/3bb827db631e9d51c7a2
#function to query the manager to see what the activation state is on the parcels
#This will (probably) cause some messy xml output, but it gets the job done.

parcel_wait_for () {
  while [ 1 ]
  do
    curl -sS -X GET -u "admin:admin" -i curl -sS -X GET -u "admin:admin" -i $BASE/clusters/$CLUSTER/parcels/products/CDH/versions/$CDH | grep '"stage" : "'$1'"' && break 
    sleep 5
  done
}

#Deploy the parcels
curl -X POST -u "admin:admin" -i $BASE/clusters/$CLUSTER/parcels/products/CDH/versions/$CDH/commands/startDistribution parcel_wait_for DISTRIBUTED

### Activate Parcels
curl -X POST -u "admin:admin" -i $BASE/clusters/$CLUSTER/parcels/products/CDH/versions/$CDH/commands/activate parcel_wait_for ACTIVATED


# Now that parcels are dealt with, we work on geting the host list
# The following are set to prevent variables set inside the loop from being reset outside the loop
set +m
shopt -s lastpipe

# Initialize the hostlist as empty
hostlist="0"
empty="0"
# Set our field separator to ":"
IFS=":"

# First, get a list of hostids from the manager:
#Here, I'm using the JQ tool which allows for command line filtering/parsing of JSON.
#JQ can be found here: https://stedolan.github.io/jq/

curl -s -u "admin:admin" "$BASE/hosts"  | jq -r ".items[] .hostId" | 
while read hostid
do 
# Now for each hostid, count the number of roles assigned to the host
# If the number of roles assigned to the host is zero, then this is a host to which we wish to add roles

	curl -s -u "admin:admin"  "$BASE/hosts/$hostid" | jq -r ".roleRefs | length" |
	while read hostroles
	do
		if [ $hostroles -eq 0 ] 
		then
			echo "adding hostid $hostid to list"
			if [ "$hostlist" == "$empty" ]
			then	
                #The host list is currently empty, so we're starting a new one
				echo "new hostlist"
				export hostlist=$hostid
				echo "host list: $hostlist "
			else
                #The host list has an entry, so we're adding more with ":" as the delimeter
				echo "adding hostid $hostid to list"
				export hostlist="$hostlist:$hostid"
			fi
		fi
	
	done
done

#If the hostlist hasn't changed from empty status, inform the user and exit

if [ "$hostlist" == "$empty" ]
	then
    echo "There are currently no hosts with unassigned roles, exiting."
    exit;
fi

#Now we should have a list of hosts to add services to ($hostlist)
#For each host on the list, we add the datanode and nodemanager role

for newhostid in $hostlist 
do 

echo ""
echo "We are adding datanote and nodemanager this hostid:"
echo $newhostid
echo ""

#Need a unique-ish number for the name
anumber=`date +"%N"`
#First the datanode:

curl -X POST -H "Content-Type:application/json" -u admin:admin \
  -d '{"items": [
{
  "name" : "hdfs-DATANODE-'$anumber'",
  "type" : "DATANODE",
  "serviceRef" : {
    "clusterName" : "cluster",
    "serviceName" : "hdfs"
  },
  "hostRef" : {
    "hostId" : "'$newhostid'"
  },
  "roleConfigGroupRef" : {
    "roleConfigGroupName" : "hdfs-DATANODE-BASE"
  }


}
   ] } ' \
   "$BASE/clusters/$CLUSTER/services/hdfs/roles"
 

#Now the nodemanager:

curl -X POST -H "Content-Type:application/json" -u admin:admin \
  -d '{"items": [
 {
    "name" : "yarn-NODEMANAGER-'$anumber'",
    "type" : "NODEMANAGER",
    "serviceRef" : {
      "clusterName" : "cluster",
      "serviceName" : "yarn"
    },
    "hostRef" : {
      "hostId" : "'$newhostid'"
    },
    "roleConfigGroupRef" : {
      "roleConfigGroupName" : "yarn-NODEMANAGER-BASE"
    }
  }
] } ' \
    "$BASE/clusters/$CLUSTER/services/yarn/roles"


done

#now that they're all setup, we start the services
echo "Starting services..."
curl -X post -u "admin:admin" "$BASE/clusters/$CLUSTER/services/hdfs/commands/start"
curl -X post -u "admin:admin" "$BASE/clusters/$CLUSTER/services/yarn/commands/start"

