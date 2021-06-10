using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.DirectoryServices;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public static class ClassGroupManager
    {
        // these are the OU's that make up the tree structure where student accounts are stored
        private static List<ClassGroup> all = new List<ClassGroup>();
        public static List<ClassGroup> All { get => all; }

        // these are the actual groups, with memberships, in Active Directory
        private static List<ADGroup> adGroups = new List<ADGroup>();
        public static List<ADGroup> ADGroups { get => adGroups; }

        public static int Count(bool endpointsOnly)
        {

            int result = 0;
            foreach (var group in All)
            {
                if (endpointsOnly)
                {
                    if (group.Children.Count == 0)
                    {
                        result++;
                    }
                    else
                    {
                        result += group.Count(endpointsOnly);
                    }
                }
                else
                {
                    result += group.Count(endpointsOnly);
                }
            }
            if (!endpointsOnly) result += All.Count;
            return result;

        }

        public static async Task<bool> Load()
        {
            return await Task.Run(() =>
            {
                all.Clear();
                bool result = LoadGroups(Connector.StudentPath, all);
                if (result)
                {
                    result = LoadADGroups(Connector.GroupPath, adGroups);
                }
                return result;
            });
        }

        private static bool LoadGroups(string path, List<ClassGroup> list)
        {
            DirectorySearcher search = Connector.GetSearcher(path);
            search.Filter = "(&(objectClass=organizationalUnit))";
            search.SizeLimit = 500;
            search.PropertiesToLoad.Clear();
            search.PropertiesToLoad.Add("ou");
            search.SearchScope = SearchScope.OneLevel;
            SearchResultCollection results;

            try
            {
                results = search.FindAll();
            }
            catch (DirectoryServicesCOMException e)
            {
                Connector.Log.AddError(Origin.Directory, e.Message);
                return false;
            }
            catch (System.Runtime.InteropServices.COMException e)
            {
                Connector.Log.AddError(Origin.Directory, e.Message);
                return false;
            } 

            foreach (SearchResult r in results)
            {
                DirectoryEntry entry = r.GetDirectoryEntry();
                list.Add(new ClassGroup());
                list.Last().DN = entry.Path;
                list.Last().Name = entry.Properties.Contains("ou") ? entry.Properties["ou"].Value.ToString() : "";
                entry.Close();
            }

            foreach (ClassGroup cg in list)
            {
                if (!LoadGroups(cg.DN, cg.Children))
                {
                    return false;
                }
            }

            return true;
        }

        private static bool LoadADGroups(string path, List<ADGroup> list)
        {
            list.Clear();
            DirectorySearcher search = Connector.GetSearcher(path);
            search.Filter = "(ObjectClass=*)";
            search.PageSize = 1000;
            search.PropertiesToLoad.Clear();
            search.PropertiesToLoad.Add("cn");
            search.PropertiesToLoad.Add("name");
            search.PropertiesToLoad.Add("sAMAccountName");
            search.PropertiesToLoad.Add("distinguishedName");
            search.SearchScope = SearchScope.OneLevel;
            SearchResultCollection results;

            try
            {
                results = search.FindAll();
            }
            catch (DirectoryServicesCOMException e)
            {
                Connector.Log.AddError(Origin.Directory, e.Message);
                return false;
            }

            foreach (SearchResult r in results)
            {
                DirectoryEntry entry = r.GetDirectoryEntry();
                if (entry.Name.StartsWith("OU")) continue;

                list.Add(new ADGroup(entry));
                entry.Close();
            }

            results.Dispose();
            return true;
        }

        public static void Sort()
        {
            all.Sort((a, b) => a.Name.CompareTo(b.Name));
            adGroups.Sort((a, b) => a.CN.CompareTo(b.CN));
        }

        public static async Task<bool> Delete(ClassGroup group)
        {
            return await Task.Run(() =>
            {
                ADGroup adGroup = ADGroups.Find((a) => a.CN.Equals(group.Name));

                ClassGroup parent = GetParent(group);
                bool result = parent.DeleteChild(group);

                if(result && adGroup != null)
                {
                    var parentEntry = Connector.GetEntry(Connector.GroupPath);
                    var childEntry = Connector.GetEntry(adGroup.DN);

                    parentEntry.Children.Remove(childEntry);
                    ADGroups.Remove(adGroup);
                }

                return result;
            });
        }

        public static ClassGroup GetParent(ClassGroup group)
        {
            foreach (var item in All)
            {
                ClassGroup result = item.GetParentOfGroup(group);
                if (result != null) return result;
            }
            return null;
        }

        public static ClassGroup Get(string nameOfGroup)
        {
            foreach (var group in All)
            {
                ClassGroup result = group.Get(nameOfGroup);
                if (result != null) return result;
            }
            return null;
        }

        public static JObject ToJson()
        {
            JObject result = new JObject();

            var groups = new JArray();
            foreach (var group in all)
            {
                groups.Add(group.ToJson());
            }
            result["Groups"] = groups;
            var list = new JArray();
            foreach (var group in adGroups)
            {
                list.Add(group.ToJson());
            }
            result["ADGroups"] = list;
            return result;
        }

        public static void FromJson(JObject obj)
        {
            All.Clear();

            if (obj.ContainsKey("Groups"))
            {
                var groups = obj["Groups"].ToArray();
                foreach (var group in groups)
                {
                    All.Add(new ClassGroup(group as JObject));
                }
            }

            if (obj.ContainsKey("ADGroups"))
            {
                var list = obj["ADGroups"].ToArray();
                foreach (var l in list)
                {
                    ADGroups.Add(new ADGroup(l as JObject));
                }
            }
        }

        public static void AddADGroup(string name)
        {
            
            DirectoryEntry ou = Connector.GetEntry(Connector.GroupPath);
            if (ou == null)
            {
                Connector.Log.AddError(Origin.Directory, "the path for groups does not exist");
                return;
            }

            DirectoryEntry newGroup = null;
            try
            {
                newGroup = ou.Children.Add($"CN={name}", "group");
                newGroup.Properties["sAmAccountName"].Value = name;
                newGroup.CommitChanges();
                ou.CommitChanges();

                newGroup.RefreshCache();
            }
            catch (DirectoryServicesCOMException e)
            {
                Connector.Log.AddError(Origin.Directory, "unable to create an AD Group for " + name);
                return;
            }
            
        }
    }
}
