using Microsoft.Graph;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Azure
{
    public class GroupManager
    {
        private static GroupManager instance;
        private GroupManager() { }
        public static GroupManager Instance { 
            get 
            {
                if (instance == null) instance = new GroupManager();
                return instance; 
            } 
        }

        IList<Group> groups = new List<Group>();
        public IList<Group> Groups => groups;

        public async Task<bool> LoadFromAzure()
        {
            try
            {
                groups = new List<Group>();

                var queryOptions = new List<QueryOption>()
                {
                    new QueryOption("$count", "true")
                };

                var results = await Connector.Instance.Directory.Groups
                    .Request(queryOptions)
                    .Header("ConsistencyLevel", "eventual")
                    .Filter("startswith(displayName, '" + Connector.Instance.Prefix + "')")
                    .Select("id,displayName,securityEnabled")
                    .GetAsync();

                while (results != null)
                {
                    foreach(var group in results.CurrentPage)
                    {
                        groups.Add(new Group(group));
                    }

                    Connector.Instance.RegisterMessage("" + groups.Count + " groepen gevonden.");
                    if (results.NextPageRequest != null)
                    {
                        results = await results.NextPageRequest.GetAsync();
                    }
                    else results = null;
                }
                for(int i = 0; i < groups.Count; i++)
                {
                    await groups[i].LoadMembers();
                    if (i % 20 == 0)
                    {
                        Connector.Instance.RegisterMessage("Leden gevonden voor " + i + " groepen.");
                    }
                    
                }
                Connector.Instance.RegisterMessage("Leden gevonden voor " + groups.Count + " groepen.");
            }
            catch (ServiceException ex)
            {
                Connector.Instance.RegisterError(ex.Message);
                return false;
            }
            return true;
        }

        public JObject ToJson()
        {
            var result = new JObject();
            var json = new JArray();
            foreach (var group in groups)
            {
                json.Add(group.ToJson());
            }
            result["Groups"] = json;
            return result;
        }

        public void FromJson(JObject obj)
        {
            groups.Clear();
            var json = obj["Groups"]?.ToArray();
            if (json != null) foreach (var item in json)
                {
                    groups.Add(new Group(item as JObject));
                }
        }

        public Group FindGroupByName(String name, bool securityGroup)
        {
            for (int i = 0; i < groups.Count; i++)
            {
                if (groups[i].DisplayName == name && groups[i].SecurityEnabled == securityGroup)
                {
                    return groups[i];
                }
            }
            return null;
        }
    }

    
}
