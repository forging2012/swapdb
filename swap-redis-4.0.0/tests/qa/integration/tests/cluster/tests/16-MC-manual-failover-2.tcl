# Check the manual failover capabilities with datacenter-id set when master is down.
# One Master One Slave

# set nodePairs 5
set OthersIndex 0
set MasterIndex 1
set SlaveIndex 2
set FailIndex 3
#othersId MasterIndex SlaveIndex FailIndex
set testcases "
                0 1 0 0
                1 0 1 0
                
                0 0 1 0
                1 1 0 0
                "
               
for {set n 0} {$n < [expr [llength $testcases]/4]} {incr n} {
    source "../tests/includes/init-tests.tcl"
    test "Create a $::nodePairs nodes cluster" {
        create_cluster $::nodePairs $::nodePairs 
    }
    set CurMaster 0
    set CurSlave $::nodePairs 

    puts "------------master:$CurMaster slave:$CurSlave--------------"
    test "Set datacenter-id others [lindex $testcases [expr $n*4+$OthersIndex]]\
    master [lindex $testcases [expr $n*4+$MasterIndex]] \
    slave [lindex $testcases [expr $n*4+$SlaveIndex]]" {
        setDatacenter_id [list $CurMaster] [lindex $testcases [expr $n*4+$MasterIndex]]
        setDatacenter_id [list $CurSlave] [lindex $testcases [expr $n*4+$SlaveIndex]]
        set nodesList ""
        for {set node 0} {$node < 10} {incr node;} {
            if {$node != $CurMaster && $node != $CurSlave} {
                lappend nodesList $node
            }
        }
        setDatacenter_id $nodesList [lindex $testcases [expr $n*4+$OthersIndex]]
        # wait for the datacenter-id broadcast to the nodes.
        after [lindex [R 0 config get cluster-node-timeout] 1]
    }

    test "Cluster is up" {
        assert_cluster_state ok
    }

    test "Cluster is writable" {
        cluster_write_test $CurMaster
    }

    test "Instance #$CurSlave is a slave" {
        assert {[RI $CurSlave role] eq {slave}}
    }

    test "Instance #$CurSlave synced with the master" {
        wait_for_condition 1000 50 {
            [RI $CurSlave master_link_status] eq {up}
        } else {
            fail "Instance #$CurSlave master link status is not up"
        }
    }

    test "Instance #$CurSlave is slave of #$CurMaster" {
        set porttmp [get_instance_attrib redis $CurMaster port]
        assert {[lindex [R $CurSlave role] 2] == $porttmp}
    }

    set current_epoch [CI 1 cluster_current_epoch]

    test "Killing one master node" {
        kill_instance redis $CurMaster
    }

    test "Instance #$CurSlave down synced with the master" {
        wait_for_condition 1000 50 {
            [RI $CurSlave master_link_status] eq {down}
        } else {
            fail "Instance #$CurSlave master link status is not down"
        }
    }

    test "Send CLUSTER FAILOVER to instance #$CurSlave with down state" {
        assert_error "*use CLUSTER FAILOVER FORCE*" {R $CurSlave cluster failover}
    }

    test "Instance #$CurSlave is still a slave after some time (no failover)" {
        after 5000
        assert {[RI $CurSlave role] eq {slave}}
    }
    
   test "Send CLUSTER FAILOVER FORCE to instance #$CurSlave" {
        R $CurSlave cluster failover force
    } 

    test "Wait for failover" {
        wait_for_condition 1000 50 {
            [CI 1 cluster_current_epoch] > $current_epoch
        } else {
            fail "No failover detected"
        }
    }

    test "Cluster should eventually be up again" {
        assert_cluster_state ok
    }

    test "Cluster is writable" {
        cluster_write_test 1
    }

    test "Instance #$CurSlave is now a master" {
        assert {[RI $CurSlave role] eq {master}}
    }

    test "Restarting the previously killed master node" {
        restart_instance redis $CurMaster
    }
        
    test "Instance #$CurMaster gets converted into a slave" {
        wait_for_condition 1000 50 {
            [RI $CurMaster role] eq {slave}
        } else {
            fail "Old master was not converted into slave"
        }
    }

    test "Instance #$CurMaster is slave of #$CurSlave" {
        set porttmp [get_instance_attrib redis $CurSlave port]
        assert {[lindex [R $CurMaster role] 2] == $porttmp}
    }
    #after 45000
    test "Wait auth_retry_time between two failovers" {
        after [expr [lindex [R $CurMaster config get cluster-node-timeout] 1]*2]
    }
}
