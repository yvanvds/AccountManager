using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    

    public static class LinkedGroups
    {
        public static Dictionary<string, LinkedGroup> List = new Dictionary<string, LinkedGroup>();

        static int totalWisaGroups = 0;
        public static int TotalWisaGroups => totalWisaGroups;

        static int totalDirectoryGroups = 0;
        public static int TotalDirectoryGroups => totalDirectoryGroups;

        static int totalSmartschoolGroups = 0;
        public static int TotalSmartschoolGroups => totalSmartschoolGroups;

        static int unlinkedWisaGroups = 0;
        public static int UnlinkedWisaGroups => unlinkedWisaGroups;

        static int unlinkedDirectoryGroups = 0;
        public static int UnlinkedDirectoryGroups => unlinkedDirectoryGroups;

        static int unlinkedSmartschoolGroups = 0;
        public static int UnlinkedSmartschoolGroups => unlinkedSmartschoolGroups;

        static int linkedWisaGroups = 0;
        public static int LinkedWisaGroups => linkedWisaGroups;

        static int linkedDirectoryGroups = 0;
        public static int LinkedDirectoryGroups => linkedDirectoryGroups;

        static int linkedSmartschoolGroups = 0;
        public static int LinkedSmartschoolGroups => linkedSmartschoolGroups;

        public static Task ReLink()
        {
            return Task.Run(() => DoRelink());
        }

        private static void DoRelink()
        {
            if (!Data.Instance.ConfigReady) return;
            if (AccountApi.Smartschool.GroupManager.Root == null) return;

            List.Clear();
            foreach(var group in AccountApi.Wisa.ClassGroupManager.All)
            {
                if(List.ContainsKey(group.Name))
                {
                    List[group.Name].wisaGroup = group;
                } else
                {
                    List.Add(group.Name, new LinkedGroup(group));
                }  
            }

            foreach(var group in AccountApi.Directory.ClassGroupManager.All)
            {

                AddDirectoryChildGroups(group);
            }

            // only compare class groups
            AccountApi.Smartschool.Group students = (AccountApi.Smartschool.Group)AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if(students != null)
            {
                AddSmartschoolChildGroups(students);
            }
            

            // count
            totalWisaGroups = totalDirectoryGroups = totalSmartschoolGroups = 0;
            unlinkedWisaGroups = unlinkedDirectoryGroups = unlinkedSmartschoolGroups = 0;
            linkedWisaGroups = linkedDirectoryGroups = linkedSmartschoolGroups = 0;
            foreach(var group in List.Values)
            {
                bool incomplete = (group.wisaGroup == null || group.smartschoolGroup == null || group.directoryGroup == null);
                if(group.wisaGroup != null)
                {
                    totalWisaGroups++;
                    if (incomplete) unlinkedWisaGroups++;
                    else linkedWisaGroups++;
                }
                if(group.smartschoolGroup != null)
                {
                    totalSmartschoolGroups++;
                    if (incomplete) unlinkedSmartschoolGroups++;
                    else linkedSmartschoolGroups++;
                }
                if(group.directoryGroup != null)
                {
                    totalDirectoryGroups++;
                    if (incomplete) unlinkedDirectoryGroups++;
                    else linkedDirectoryGroups++;
                }
            }

            // add actions
            foreach(var group in List.Values)
            {
                group.Compare();
            }
        }

        private static void AddSmartschoolChildGroups(AccountApi.Smartschool.Group group)
        {
            if(group.Official)
            {
                if(List.ContainsKey(group.Name))
                {
                    List[group.Name].smartschoolGroup = group;
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

        private static void AddDirectoryChildGroups(AccountApi.Directory.ClassGroup group)
        {
            if(!group.IsContainer)
            {
                if (List.ContainsKey(group.Name))
                {
                    List[group.Name].directoryGroup = group;
                }
                else
                {
                    List.Add(group.Name, new LinkedGroup(group));
                }
            }
            foreach(var child in group.Children)
            {
                AddDirectoryChildGroups(child);
            }
        }
    }
}
