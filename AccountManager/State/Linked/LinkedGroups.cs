﻿using AbstractAccountApi;
using AccountManager.Action.Group;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{

    public class Groups
    {
        public Dictionary<string, LinkedGroup> List = new Dictionary<string, LinkedGroup>();

        int totalWisaGroups = 0;
        public int TotalWisaGroups => totalWisaGroups;

        int totalSmartschoolGroups = 0;
        public int TotalSmartschoolGroups => totalSmartschoolGroups;

        int unlinkedWisaGroups = 0;
        public int UnlinkedWisaGroups => unlinkedWisaGroups;

        int unlinkedSmartschoolGroups = 0;
        public int UnlinkedSmartschoolGroups => unlinkedSmartschoolGroups;

        int linkedWisaGroups = 0;
        public int LinkedWisaGroups => linkedWisaGroups;

        int linkedSmartschoolGroups = 0;
        public int LinkedSmartschoolGroups => linkedSmartschoolGroups;

        public async Task ReLink()
        {
            await Task.Run(() => DoRelink()).ConfigureAwait(false);
            App.Instance.Linked.UpdateObservers();
        }

        private void DoRelink()
        {
            //if (!Data.Instance.ConfigReady) return;
            if (AccountApi.Smartschool.GroupManager.Root == null) return;

            List.Clear();
            foreach(var group in AccountApi.Wisa.ClassGroupManager.All)
            {
                if(List.ContainsKey(group.FullName))
                {
                    List[group.FullName].Wisa.Group = group;
                } else
                {
                    List.Add(group.FullName, new LinkedGroup(group));
                }  
            }


            // only compare class groups
            AccountApi.Smartschool.Group students = (AccountApi.Smartschool.Group)AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if(students != null)
            {
                AddSmartschoolChildGroups(students);
            }
            

            // count
            totalWisaGroups = totalSmartschoolGroups = 0;
            unlinkedWisaGroups = unlinkedSmartschoolGroups = 0;
            linkedWisaGroups = linkedSmartschoolGroups = 0;
            foreach(var group in List.Values)
            {
                bool incomplete = (group.Wisa.Group == null || group.Smartschool.Group == null);
                if(group.Wisa.Group != null)
                {
                    totalWisaGroups++;
                    if (incomplete) unlinkedWisaGroups++;
                    else linkedWisaGroups++;
                }
                if(group.Smartschool.Group != null)
                {
                    totalSmartschoolGroups++;
                    if (incomplete) unlinkedSmartschoolGroups++;
                    else linkedSmartschoolGroups++;
                }
            }

            // add actions
            foreach(var group in List.Values)
            {
                GroupActionParser.AddActions(group);
            }
        }

        private void AddSmartschoolChildGroups(AccountApi.Smartschool.Group group)
        {
            if(group.Official)
            {
                if(List.ContainsKey(group.Name))
                {
                    List[group.Name].Smartschool.Group = group;
                } else
                {
                    List.Add(group.Name, new LinkedGroup(group));
                }
                
            }


            if(group.Children != null) foreach(var child in group.Children)
            {
                if(child != null)
                AddSmartschoolChildGroups(child as AccountApi.Smartschool.Group);
            }
        }

    }
}
