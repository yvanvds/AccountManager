using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.DisplayItems
{
    public class ADGroup
    {
        public ObservableCollection<ADGroup> Children { get; set; }
        public AccountApi.Directory.ClassGroup Base;
        public string Header { get; set; } = "No Groups Found";
        public string Icon { get; set; } = "QuestionMarkBox";

        public ADGroup(AccountApi.Directory.ClassGroup Base)
        {
            this.Base = Base;
            Children = new ObservableCollection<ADGroup>();

            Header = Base.Name;

            if (Base == null) return;
            if (Base.Children.Count == 0)
            {
                Icon = "Class";
            }
            else
            {
                Icon = "UserGroup";
                foreach (var group in Base.Children)
                {
                    Children.Add(new ADGroup(group));
                }
            }
        }
    }
}
