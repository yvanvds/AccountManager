using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class RemoveDirectoryClassGroup : IAction
    {
        public string Header => "Active Directory Klas Verwijderen";

        public string Description => "Je kan deze klas niet verwijderen uit Active Directory omdat" +
            " ze niet leeg is. Verwijder of verplaats eerst de leerlingen in deze klas.";

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public bool CanBeApplied => false;

        public async Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }
    }
}
