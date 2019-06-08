using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Directory
{
    public class ClassGroup
    {
        public string DN;
        //public string Path;
        public string Name;
        public List<ClassGroup> Children = new List<ClassGroup>();

        public ClassGroup() { }

        public ClassGroup(JObject obj)
        {
            DN = obj.ContainsKey("dn") ? obj["dn"].ToString() : "";
            //Path = obj.ContainsKey("path") ? obj["path"].ToString() : "";
            Name = obj.ContainsKey("name") ? obj["name"].ToString() : "";
            if (obj.ContainsKey("children"))
            {
                var children = obj["children"].ToObject<JArray>();
                foreach (var child in children)
                {
                    Children.Add(new ClassGroup(child as JObject));
                }
            }
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["dn"] = DN,
                //result["path"] = Path;
                ["name"] = Name
            };
            var children = new JArray();
            foreach (var child in Children)
            {
                children.Add(child.ToJson());
            }
            result["children"] = children;
            return result;
        }

        public bool IsContainer { get => Children.Count > 0; }

        public int Count(bool endpointsOnly)
        {
            int result = 0;
            foreach (var group in Children)
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
            if (!endpointsOnly) result += Children.Count;
            return result;
        }

        public ClassGroup Get(string nameOfGroup)
        {
            if (Name.Equals(nameOfGroup, StringComparison.CurrentCultureIgnoreCase))
            {
                return this;
            }

            foreach (var group in Children)
            {
                ClassGroup result = group.Get(nameOfGroup);
                if (result != null) return result;
            }
            return null;
        }

        public ClassGroup GetParentOfGroup(ClassGroup child)
        {
            foreach (var group in Children)
            {
                if (group == child) return this;
            }

            foreach (var group in Children)
            {
                var parent = group.GetParentOfGroup(child);
                if (parent != null) return parent;
            }
            return null;
        }

        public bool DeleteChild(ClassGroup child)
        {
            bool found = false;
            foreach (var group in Children)
            {
                if (group == child) found = true;
            }
            if (!found) return false;

            var parentEntry = Connector.GetEntry(DN);
            var childEntry = Connector.GetEntry(child.DN);

            parentEntry.Children.Remove(childEntry);
            Children.Remove(child);
            return true;
        }
    }
}
