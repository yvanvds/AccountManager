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
        private static List<ClassGroup> all = new List<ClassGroup>();
        public static List<ClassGroup> All { get => all; }

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
                return LoadGroups(Connector.StudentPath, all);
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

        public static void Sort()
        {
            all.Sort((a, b) => a.Name.CompareTo(b.Name));
        }

        public static async Task<bool> Delete(ClassGroup group)
        {
            return await Task.Run(() =>
            {
                ClassGroup parent = GetParent(group);
                return parent.DeleteChild(group);
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
            return result;
        }

        public static void FromJson(JObject obj)
        {
            All.Clear();

            var groups = obj["Groups"].ToArray();
            foreach (var group in groups)
            {
                All.Add(new ClassGroup(group as JObject));
            }
        }
    }
}
